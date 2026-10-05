# Lab image

One image serves the head and every worker; firstboot picks the role (see
[Provisioning](../architecture/provisioning.md)). This page covers what a
"lab-ready" image contains, in particular the sphinx-asr workload, and how
CI proves the image matches the sources it was built from.

## Contents

| Layer | Source | What it adds |
| --- | --- | --- |
| Base OS | `pi-gen` submodule stages 0 to 2, pinned to pi-gen's `arm64` branch | Raspberry Pi OS Lite equivalent: Debian 13 trixie, **arm64**, firmware, kernel, SSH |
| Cluster base | `stages/stage-ivalice-base/00-ivalice-base/` | Slurm, munge, k3s (server and agent, both disabled), Podman, cloud-init, Ansible tree, build tools (`build-essential`, `cmake`, `clang`, `python3-venv`), zsh, firstboot units; see [Build pipeline](../architecture/build-pipeline.md#the-custom-stage-stagesstage-ivalice-base) |
| Workload | `stages/stage-ivalice-base/10-sphinx-asr/` | sphinx-asr at the pinned commit in `/srv/ivalice/sphinx-asr`, with tools and venv prebuilt (below) |

!!! warning "pi-gen pin"
    Until 2026-10-05 the `pi-gen` submodule sat on pi-gen's `master`
    branch, which builds **32-bit armhf** (`export ARCH=armhf` in
    `pi-gen/build.sh`), while `configs/config.base` and the k3s assets
    assume arm64. The submodule now points at the tip of pi-gen's `arm64`
    branch (`4d8ee44`), and `scripts/ci/build-image.sh` refuses to build if
    the pinned pi-gen does not export `ARCH=arm64`.

## The sphinx-asr payload

After `stages/stage-ivalice-base/10-sphinx-asr/` runs, the image has:

| Path | Content |
| --- | --- |
| `/srv/ivalice/sphinx-asr/` | `git archive` of the pinned submodule commit: no `.git`, no untracked files, no build products from the operator's machine |
| `/srv/ivalice/sphinx-asr/bin/aarch64/` | 45 tools built natively in the image's chroot: sphinxtrain (`sphinx_fe`, `bw`, `norm`, ...), pocketsphinx (`pocketsphinx`, `pocketsphinx_batch`, `pocketsphinx_lm_convert`) and the CMU-Cambridge LM toolkit (`text2wfreq`, `idngram2lm`, `evallm`, ...) |
| `/srv/ivalice/sphinx-asr/.venv/` | Python venv with `requirements.txt` (pyyaml, numpy, scipy) installed |
| `/srv/ivalice/sphinx-asr/IMAGE-MANIFEST.txt` | sphinx-asr commit, image build hash, build date, gcc, cmake, perl and Python versions, `pip freeze`, and `ls -l` and `file` output for `bin/aarch64/*` |
| `/usr/local/bin/sphinx` | symlink to `sphinx.sh` (the Makefile's `link` target) |
| `/etc/profile.d/sphinx-asr.sh` | exports `SPHINX_ROOT=/srv/ivalice/sphinx-asr` for every login, and for `ivalice` puts `.venv/bin` and `bin/aarch64` first on `PATH`; also sourced from `/etc/zsh/zprofile`, because `ivalice` logs in with zsh, which does not read `/etc/profile.d` |

Everything under `/srv/ivalice` is owned `1000:1000` (`ivalice:ivalice`),
which the NFS export from the head relies on. The vendor build trees are
deleted after `make`; only `bin/aarch64/` is kept.

### How the commit is pinned

`stages/stage-ivalice-base/10-sphinx-asr/00-run.sh` runs on the build host
before the chroot step and stops the build if:

- `sphinx-asr/` is not a checked-out submodule;
- the submodule's `HEAD` differs from the gitlink the superproject records
  (`git ls-files --stage sphinx-asr`), for example after a `git checkout`
  inside the submodule without a pointer bump;
- the submodule has uncommitted changes to tracked files.

It then exports exactly that commit with `git archive`. The stage finds the
repository through `IVALICE_REPO_ROOT`: `scripts/_pigen-podman.sh` mounts
the repo read-only at `/ivalice-repo` in the Podman container and sets it,
`scripts/ci/build-image.sh` sets it to the CI checkout, and any other
native build falls back to the parent of `stages/`.

The submodule tree commits x86 object files under
`sphinx-asr/vendor/cmu_toolkit/src/`, and the Makefile's `clean` target
does not remove them. A plain `make clean && make` on a fresh export fails
on aarch64 (`SLM2.a: error adding symbols: file in wrong format`,
reproduced in the `pigen-builder` VM on 2026-10-05), so `00-run.sh` deletes
every `*.o` and `*.a` under `vendor/` before the build. With that, the full
vendor build took 8 seconds natively in the VM.

### Build-time network, runtime airgap

The chroot step (`01-run-chroot.sh`) runs `make clean && make` and then
`python3 -m venv .venv` and `pip install -r requirements.txt`. That pip
install is the only network access the stage makes, and it happens at
image build time. `00-run.sh` gives the chroot the build host's resolver
for it (pi-gen mounts an empty tmpfs on `/run`, so the image's
`stub-resolv.conf` symlink dangles inside the chroot), and `02-run.sh`
restores the symlink.

`sphinx.sh` creates a venv and runs `pip install` only when
`.venv/bin/python3` is missing. Because the venv is prebuilt, nothing in
sphinx-asr reaches the network after boot; `verify-image` runs `sphinx.sh`
in the image to confirm that.

!!! warning "Drift"
    `CLAUDE.md` describes `10-sphinx-asr/` as copying the sphinx-asr tree
    "+ wheels" from `assets/sphinx-wheels/`. No wheel cache exists: the venv
    is installed from PyPI at build time, so numpy, scipy and pyyaml
    versions float between builds. The exact versions of each image are in
    its `IMAGE-MANIFEST.txt` (`pip freeze`). Pinning them needs a
    constraints file or a wheel cache, which belong in the sphinx-asr repo.

No packages are installed or purged by the sub-stage: its build
dependencies (`build-essential`, `cmake`, `python3-venv`) are already part
of `00-ivalice-base`'s package list, which keeps a development toolset on
the nodes on purpose.

## Verification

`scripts/ci/verify-image.sh` runs in the `verify-image` job (or by hand,
see [GitLab CI](gitlab-ci.md#running-a-build-by-hand)). It attaches the
image read-only with `losetup -P`, mounts the root partition
`ro,noload`, and reports each check as TAP on stdout and as JUnit XML for
GitLab's test report. The image is never written to: chroot commands get
tmpfs `/tmp` and `/run`, and pytest is installed on the host into a
throwaway directory that is copied into that tmpfs.

| Group | Checks |
| --- | --- |
| image | raw image sha256 equals `image-manifest.json` |
| os | `VERSION_CODENAME=trixie`; `dpkg --print-architecture` is `arm64`; `/usr/bin/dpkg` is an aarch64 ELF |
| sphinx-asr | the tree and `IMAGE-MANIFEST.txt` exist; the commit in the manifest equals the sphinx-asr sha in `image-manifest.json`; no `.git`; everything under `/srv/ivalice` is `1000:1000` |
| bin | each of the 45 expected tools exists, is an aarch64 ELF, and has all shared libraries resolvable (`ldd` in the chroot); every file in `bin/aarch64/` is aarch64 |
| venv | `.venv/bin/python3` exists; as `ivalice`, the venv imports `yaml`, `numpy` and `scipy`; `sphinx.sh` prints its usage without creating a venv; the profile snippet sets `SPHINX_ROOT` and puts `sphinx_fe` and the venv's `python3` on `PATH`; `/etc/zsh/zprofile` sources it |
| pytest | sphinx-asr's own test suite passes in the image's venv, as `ivalice` |
| units | the build-time asserts from `stages/stage-ivalice-base/00-ivalice-base/01-run.sh`: munge enabled, `slurmctld` and `slurmd` not enabled, `k3s` and `k3s-agent` disabled; plus `ivalice-firstboot.service` enabled |

Exit codes: 0 all passed, 1 a check failed, 2 usage error, 3 setup error.

## Known gaps

- **IC-4:** the image still ships the published `FIRST_USER_PASS`,
  `PUBKEY_ONLY_SSH=0` and passwordless sudo. CI does not change that; see
  the warning in [GitLab CI](gitlab-ci.md).
- **IC-9:** the Podman path still has no manifest and uses a timestamp as
  `GIT_HASH`; the CI path records the repo sha and input hashes.
  `scripts/download-assets.sh` still fetches oh-my-zsh from `master` and the
  k3s installer unpinned, so two CI builds of the same commit can differ.
  The manifest's input hashes show when they do.
- **SA-19, SA-20:** `sphinx.sh` and the sphinx-asr Makefile issues from the
  [baseline review](../reviews/2026-10-04-baseline.md) are untouched; the
  stage works around the incomplete `make clean`.
