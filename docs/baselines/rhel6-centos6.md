# CentOS 6.10 legacy baseline VM

This page documents the "legacy OS on new hardware" cell of the
[baseline design](index.md): a CentOS 6.10 x86_64 virtual machine that
reproduces the RHEL 6.x software environment of UNH's Dell HPC servers, so
that sphinx-asr can be built and checked with the legacy toolchain on the
workstation. The scripts live in `baselines/rhel6/` (see its README for the
file list).

!!! warning "Timings from this VM are not valid"
    The workstation is an Apple M4 Max (arm64). RHEL and CentOS 6 were never
    built for aarch64, so the VM runs under QEMU TCG: every x86_64
    instruction is translated in software, with no hardware acceleration.
    Wall-clock numbers from it say nothing about the hardware and must not
    appear in hardware comparisons. The VM **is** valid for correctness and
    accuracy: whether gcc 4.4.7, glibc 2.12 and perl 5.10 produce the same
    features, models and WER as the modern toolchain. For timings, run the
    same scripts on an x86_64 Linux host with KVM (`ACCEL=kvm`).

## Why CentOS 6.10 approximates RHEL 6.x

CentOS 6 is a rebuild of the RHEL 6 source RPMs with the Red Hat branding
removed. Packages are built from the same sources with the same compiler
and flags, so the binaries are compatible: the same gcc 4.4.7, glibc 2.12,
perl 5.10.1, Python 2.6.6 and kernel 2.6.32 series. Differences that remain:

- **Minor release.** CentOS 6.10 matches RHEL 6.10, the last 6.x minor
  release (2018). If the Dells run an earlier minor release (for example
  6.5 or 6.7), they have older errata of the same packages. The major
  versions above are fixed across all of RHEL 6, but individual library
  patches (glibc math functions, for instance) can differ. Record the
  Dells' `/etc/redhat-release`, `rpm -q glibc gcc perl` and `uname -r` and
  compare them with the manifest below.
- **Errata level.** The image is the final GenericCloud build (`1907`,
  2019-07) and provisioning installs from the frozen 6.10 `os` and
  `updates` trees on vault.centos.org, so the VM is at the last CentOS 6
  errata level. A Dell that has not been updated since installation sits
  at its minor release's GA package set.
- **Extended support.** RHEL 6 ELS (paid, to 2024) shipped fixes that
  never reached CentOS. They are security fixes and do not touch the
  toolchain.
- **Kernel tuning and drivers.** The kernel is a virtual machine kernel on
  emulated hardware. This affects nothing the compute path computes.

### Re-pinning to another 6.x minor release

To match a Dell running, say, RHEL 6.7:

1. In `baselines/rhel6/guest/CentOS-Vault-6.10.repo`, replace `6.10` with
   `6.7` in every `baseurl` (vault.centos.org keeps every minor release:
   `https://vault.centos.org/6.7/os/x86_64/`). Rename the file to match
   and update its name in `make-seed.sh` and `provision.sh`.
2. Optionally pick an older GenericCloud image from
   `https://cloud.centos.org/centos/6/images/` (`1508` to `1601` are 6.7
   era) and set `IMAGE_NAME` and `IMAGE_SHA256` in `_common.sh` from the
   published `sha256sum.txt`. Keeping the 6.10 image and only pinning yum
   to the older tree also works, but the base packages in the image stay at
   6.10.
3. Run `./vm.sh destroy --yes`, then `up`, `provision.sh` and
   `run-checks.sh`, and commit the new `results/TOOLCHAIN-MANIFEST.txt`.

## Why plain QEMU and not Lima

Lima 2.2.1 is installed, but it cannot host CentOS 6:

- Lima's guest agent is a Go binary; the one shipped with Lima 2.2.1
  reports `go1.27.1` (`go version` on the unpacked agent). Since Go 1.24
  the Go runtime requires Linux 3.2 or newer (Go 1.24 release notes:
  "Go 1.24 requires Linux kernel version 3.2 or later"). CentOS 6 runs
  2.6.32.
- Lima's boot scripts install the agent as a systemd unit (or an OpenRC
  service on Alpine); CentOS 6 uses Upstart and SysV init.
- The Homebrew Lima on this host ships only `Linux-aarch64` guest agents;
  an x86_64 guest additionally needs Lima's separate additional-guestagents
  package.

The scripts therefore drive `qemu-system-x86_64` directly with a cloud-init
NoCloud seed ISO. CentOS 6's cloud-init is 0.7.5, which supports NoCloud,
`users`, `write_files`, `bootcmd` and `runcmd`; the seed uses nothing newer.

## Security posture

CentOS 6 reached end of life on 2020-11-30 and receives no security
updates. Its OpenSSH (5.3p1), OpenSSL (1.0.1e) and kernel have known
vulnerabilities. The VM is built so that nothing can reach it:

- QEMU user-mode networking only. The single port forward binds
  `127.0.0.1:2226` to the guest's sshd; no bridge, no tap device, nothing on
  a routable address. Never change `SSH_BIND` in `_common.sh`.
- Key-only ssh for user `baseline` with a dedicated key generated into
  `baselines/rhel6/.state/` (gitignored). The operator's own keys are never
  read or copied. Password authentication is off and the root password is
  locked.
- The host ssh client re-enables the `ssh-rsa` host-key algorithm for this
  VM only (`_common.sh`), because OpenSSH 5.3p1 offers nothing newer. The
  user key is ECDSA P-256: RHEL backported ECDSA to 5.3p1 but not ed25519.
- `vault-proxy.py`, used during provisioning, binds `127.0.0.1:8610` only
  and serves only the 6.10 vault trees. The guest reaches it as `10.0.2.2`
  through QEMU's user-mode network. Plain HTTP on that hop does not weaken
  package integrity because yum verifies every package against the CentOS
  and SCLo GPG keys (`gpgcheck=1`).
- Do not store real credentials, tokens or personal data in the VM.

## Usage

Prerequisites on the host: `qemu-system-x86_64`, `qemu-img` and `xorriso`
(Homebrew), `python3`, `git`, `curl`.

```sh
cd baselines/rhel6
./fetch-image.sh   # image + deps.lock, all sha256-verified, into .cache/
./vm.sh up         # creates the 40G overlay and seed, boots, waits for sshd
./provision.sh     # resumable; see the phase list below
./run-checks.sh    # pytest, tool sanity, compiler audit -> results/
./vm.sh down       # clean poweroff; overlay kept
```

Other commands: `./vm.sh status`, `./vm.sh ssh [CMD]`,
`./vm.sh destroy --yes` (deletes the overlay; the cached image and VM key
stay). Tunables are environment variables read by `vm.sh`: `ACCEL`
(default `tcg`), `CPU_MODEL` (`Nehalem`), `SMP` (4), `MEM` (`8G`),
`OVERLAY_SIZE` (`40G`), `SSH_PORT` (2226), `MACHINE` (`q35`).

On an x86_64 Linux host with KVM, the timing-valid variant is:

```sh
ACCEL=kvm CPU_MODEL=host ./vm.sh up
```

### What provisioning does

| Phase | What happens | Compiler |
| --- | --- | --- |
| stage | `git archive HEAD` of the sphinx-asr submodule, cmake, Python source and wheelhouse copied to `~/stage` | none |
| packages | gcc, gcc-c++, make, perl, bison, flex, swig, zlib-devel and friends from the 6.10 vault; devtoolset-8-gcc from SCLo; Kitware cmake 3.25.3 unpacked to `/opt/cmake-3.25.3` | none |
| grow | `growpart` the root partition to the 40G overlay, reboot, `resize2fs` | none |
| python | Python 3.12.15 built into `/opt/py312` | devtoolset-8 gcc 8.3.1 |
| venv | `.venv` in the guest copy of sphinx-asr, from `/opt/py312`, offline install of pytest and PyYAML | none (PyYAML pure Python) |
| sphinx | delete prebuilt `*.o`/`*.a` under `vendor/`, then `make clean && make` | system gcc 4.4.7 |
| manifest | `~/TOOLCHAIN-MANIFEST.txt` | none |

### Running an experiment

No speech corpus is staged on the workstation yet. `run-experiment.sh` is
the hook for that step: given a corpus name with a definition under
`sphinx-asr/corpus/` and a host directory holding its data, it copies the
data into the guest and runs `sphinx.sh feats`, `new`, `setup`, `train` and
`decode`, saving the transcript under `results/experiments/`. It has not
been exercised; check its output on the first run.

## Python: orchestration only

The sphinx-asr scripts (`sphinx-asr/scripts/*.py`) need Python 3.12 or newer; CentOS 6 ships
Python 2.6.6. Python only orchestrates: it writes configuration, file
lists and transcripts, and starts the Perl and C tools. The compute path
(sphinxtrain, pocketsphinx, cmu_toolkit, plus Perl 5.10.1) does not run
through Python. The least invasive choice that keeps the compute path on
the legacy toolchain is:

- **Build Python 3.12.15 from source into `/opt/py312`.** Python 3.12 needs
  a C11 compiler, which gcc 4.4.7 is not, so it is built with
  devtoolset-8 (gcc 8.3.1) from the SCLo vault repository. devtoolset-8 is
  not on `PATH` and is used for nothing else; the sphinx-asr build sets
  `CC=/usr/bin/gcc` explicitly and the check script fails if any built
  binary records a different compiler.
- **No `ssl`, `_hashlib`, `_sqlite3`, `_tkinter`, `_dbm`, `_uuid`.** Python
  3.12 needs OpenSSL 1.1.1; CentOS 6 has 1.0.1e. sphinx-asr does not use
  these modules, and `hashlib` falls back to Python's built-in
  implementations.
- **Offline wheelhouse.** Without `ssl`, pip cannot reach PyPI, so
  `fetch-image.sh` downloads a pinned wheelhouse on the host
  (`baselines/rhel6/deps.lock`) and pip installs with `--no-index`. Every
  wheel is pure Python (`py3-none-any`). PyYAML 6.0.3 is installed from its
  sdist and falls back to its pure-Python loader (no libyaml), which is all
  `sphinx-asr/scripts/lib/config.py` needs. `manylinux2014` wheels would not load:
  they require glibc 2.17 and CentOS 6 has 2.12.
- **numpy and scipy are not installed.** `requirements.txt` lists them, but
  no sphinx-asr script imports them, and the pytest suite does not need
  them. Only sphinxtrain's optional LDA/MLLT steps call them (through
  `python`), and the experiment template disables those
  (`CFG_LDA_MLLT: "no"`). Running LDA/MLLT here would mean building numpy
  and scipy from source with devtoolset-8, gfortran and a LAPACK, which
  would also move part of the numerics off the legacy toolchain; that is
  left out on purpose.

## Building sphinx-asr with gcc 4.4.7

`git archive HEAD` of the submodule (pinned at `7745786`) is unpacked in
the guest and built with `make clean && make` using `/usr/bin/gcc` 4.4.7.
Two things needed attention.

**Prebuilt objects in the submodule.** `vendor/cmu_toolkit/src` tracks 24
x86-64 object files whose `.comment` section reads
`GCC: (Ubuntu 14.2.0-4ubuntu2~24.04.1) 14.2.0`. A fresh checkout gives
them the same modification time as their sources, so `make` treats them as
up to date and links them unchanged: on any x86_64 machine, the
cmu_toolkit binaries would silently contain GCC 14 code. Provisioning
deletes every `*.o` and `*.a` under `vendor/` before building, and
`run-checks.sh` audits the `.comment` section of every built binary. The
files should also be removed from the sphinx-asr repository itself.

**pocketsphinx 5.0.4 does not compile with gcc 4.4.7 as shipped.** The
exact errors:

```
include/pocketsphinx.h:130: error: redefinition of typedef 'ps_config_t'
include/pocketsphinx/model.h:57: note: previous declaration of 'ps_config_t' was here
include/pocketsphinx.h:136: error: redefinition of typedef 'ps_decoder_t'
include/pocketsphinx/search.h:97: note: previous declaration of 'ps_decoder_t' was here
src/lm/fsg_model.h:124: error: redefinition of typedef 'fsg_model_t'
src/util/genrand.c:101: error: '__thread' before 'static'
src/util/genrand.c:102: error: '__thread' before 'static'
```

Repeating a typedef is legal in C11 and accepted by gcc 4.6 and later, but
gcc 4.4 rejects it in every mode. gcc's `__thread` must follow `static`,
while C11's `_Thread_local` may precede it. The fix is a
declaration-only patch, `baselines/rhel6/patches/gcc44-pocketsphinx.patch`,
applied with `patch -p1` to the guest copy only (the submodule is not
touched): it drops the three repeated typedefs and writes
`static PS_THREAD_LOCAL` instead of `PS_THREAD_LOCAL static`. No compiler
flags changed and no compiler was swapped. sphinxtrain and cmu_toolkit
built unmodified; the Makefile's `-w` hides their warnings.

The build needs cmake 3.25 (`vendor/pocketsphinx` requires it), and CentOS
6 ships 2.8.12, so Kitware's static cmake 3.25.3 binary is unpacked to
`/opt/cmake-3.25.3` (it needs only `GLIBC_2.10`). cmake drives the build;
it does not compile anything itself.

## Results

All artifacts are in `baselines/rhel6/results/`: `TOOLCHAIN-MANIFEST.txt`
(versions, per-binary compiler audit, `file` output, `rpm -qa`) and
`run-checks.txt` (pytest and tool checks).

### Toolchain manifest headline

| Component | Version | Role |
| --- | --- | --- |
| OS | CentOS release 6.10 (Final) | |
| Kernel | 2.6.32-754.17.1.el6.x86_64 | |
| glibc | 2.12-1.212.el6_10.3 | |
| gcc, g++ | 4.4.7 20120313 (Red Hat 4.4.7-23) | compute path |
| binutils | 2.20.51.0.2-5.48.el6_10.1 | compute path |
| GNU make | 3.81 | compute path |
| perl | 5.10.1 (perl-5.10.1-144.el6) | compute path (sphinxtrain scripts) |
| bison, flex, swig | 2.4.1, 2.5.35, 1.3.40 | build tools |
| Python 2 | 2.6.6 | system only, unused |
| Python 3 | 3.12.15 in `/opt/py312` | orchestration only |
| devtoolset-8 gcc | 8.3.1 20190311 | builds Python 3.12 only |
| cmake | 3.25.3 (Kitware static) | build driver only |
| pytest, PyYAML | 9.1.1, 6.0.3 (pure Python) | tests, config loading |
| sphinx-asr | `77457866be77f33b5c187bfaf5bd0cd24926ce9f` | |

All 45 binaries in the guest's `bin/x86_64/` are dynamically linked x86-64
ELF executables ("for GNU/Linux 2.6.18") whose `.comment` section names
only `GCC: (GNU) 4.4.7 20120313 (Red Hat 4.4.7-23)`.

### Checks

- pytest: 73 passed, 4 xfailed (the four known-defect tests in
  `sphinx-asr/tests/scripts/test_known_defects.py`, as on the host).
- `sphinx_fe` and `bw` start and print their argument tables.
- `pocketsphinx_batch`, `text2wfreq` and `idngram2lm` are present.
- Compiler audit: no binary reports a compiler other than GCC 4.4.7.

### Phase durations under TCG

These are recorded to plan work, not as results: they are emulation
timings and say nothing about any hardware.

Clean run from `./vm.sh destroy --yes` on 2026-10-05 (M4 Max, QEMU 11.1.2,
TCG, 4 vCPUs, 8 GiB), with the vault package cache already warm:

| Phase | Duration |
| --- | --- |
| `vm.sh up` (boot to sshd, first boot with cloud-init) | 107 s |
| stage inputs, yum `packages` | 213 s (plus staging) |
| grow partition, reboot, `resize2fs` | about 80 s |
| `python` (configure, `make -j4`, install) | 706 s |
| `venv` | 79 s |
| `sphinx` (`make clean && make`, gcc 4.4.7, `-j4`) | 137 s |
| whole `provision.sh` | 1260 s (21 min) |
| `run-checks.sh` (pytest suite itself: 3 s) | 16 s |

Two complete runs (the first before the clean rebuild) produced manifests
that differ only in the generation timestamp and these durations: the same
package set, versions and per-binary compiler records.
