# ivaliceCluster

A small, fully reproducible HPC research cluster built from a single
unified pi-gen image. Targets a DeskPi Super6c carrier with six
Raspberry Pi CM4 Lite modules (aarch64, 4 cores, 8 GB each), running
Debian 13 Trixie with Slurm + munge + (optional) k3s, on a
private /24 with no internet at runtime.

The cluster runs CMU Sphinx (sphinx-asr) ASR training and decoding
jobs through `sbatch`. Slurm is the de-facto compute interface; k3s
is opt-in for container workloads. Designed as a modernization of
RHEL-6.x-era HPC tooling: Trixie as base, distro-packaged Slurm,
Ansible for postboot convergence, cloud-init for role dispatch.

## Hardware

| Role     | Hostname  | IP          |
| -------- | --------- | ----------- |
| Head     | dalmasca  | 10.42.0.1   |
| Worker   | archadia  | 10.42.0.11  |
| Worker   | rozarria  | 10.42.0.12  |
| Worker   | bhujerba  | 10.42.0.13  |
| Worker   | nabradia  | 10.42.0.14  |
| Worker   | kerwon    | 10.42.0.15  |

Single user across all nodes: `ivalice` (UID 1000).

## Quick start

The image is built on a macOS or Linux workstation via privileged
Podman; pi-gen does not run on macOS directly. You'll also need
roughly 15 GB of free disk for `pi-gen/work/` and the deploy artifact.

```sh
# 1. Clone with submodules
git clone --recurse-submodules <repo-url> ivaliceCluster
cd ivaliceCluster

# 2. Bootstrap airgap payloads (one-time, while online).
#    Pulls k3s + oh-my-zsh tarball, generates cluster keys.
./scripts/download-assets.sh
./scripts/generate-ssh-key.sh
./scripts/generate-munge-key.sh
./scripts/generate-token.sh

# 3. Build the image. Output lands in pi-gen/deploy/*.img.
./scripts/build.sh

# 4. Flash one image per node, then personalize each SD card with
#    its hostname/IP/role. The script writes
#    /boot/firmware/ivalice-node.conf onto the bootfs partition.
./scripts/personalize-node.sh --hostname dalmasca --ip 10.42.0.1  --role head
./scripts/personalize-node.sh --hostname archadia --ip 10.42.0.11 --role worker
./scripts/personalize-node.sh --hostname rozarria --ip 10.42.0.12 --role worker
./scripts/personalize-node.sh --hostname bhujerba --ip 10.42.0.13 --role worker
./scripts/personalize-node.sh --hostname nabradia --ip 10.42.0.14 --role worker
./scripts/personalize-node.sh --hostname kerwon   --ip 10.42.0.15 --role worker

# 5. Boot the head first so slurmctld and nfs-server come up; then
#    boot workers. The head waits for >= 3 workers to respond before
#    running site.yml.

# 6. Verify
ssh ivalice@dalmasca
sinfo                        # 5 workers idle
mountpoint /srv/ivalice      # NFSv4 mount on workers
```

## Repo layout

```
ivaliceCluster/
  configs/config.base                  pi-gen build config (Trixie arm64)
  pi-gen/                              upstream pi-gen (submodule)
  sphinx-asr/                          ASR workload (submodule)
  assets/                              airgap payloads (gitignored;
                                       see assets/README.md to populate)
  scripts/
    build.sh                           top-level image build (podman wrapper)
    _pigen-podman.sh                   pi-gen + podman quirks (losetup-f
                                       sanitize, util-linux 2.41 fix, etc.)
    download-assets.sh                 fetch k3s + oh-my-zsh
    generate-{ssh,munge,token}-key.sh  cluster keypair, munge key, k3s token
    personalize-node.sh                stamp /boot/firmware/ivalice-node.conf
                                       onto a flashed SD
  stages/stage-ivalice-base/           custom pi-gen stage
    00-ivalice-base/00-packages        apt deb list (slurm, munge, nfs,
                                       ansible, k3s deps)
    00-ivalice-base/01-run.sh          chroot setup
    00-ivalice-base/files/             rootfs overlay (/etc, /opt/ivalice,
                                       /home/ivalice, systemd units, etc.)
  docs/uml/                            Phase 0 design diagrams
                                       (5 packages, 26 PlantUML sources)
```

The image build is documented diagrammatically in
[`docs/uml/01-build-lifecycle/`](docs/uml/01-build-lifecycle/). The
proposed Slurm integration for sphinx-asr's training/decoding is in
[`docs/uml/04-slurm-integration/`](docs/uml/04-slurm-integration/).

Render diagrams with:

```sh
plantuml -tsvg -tpng docs/uml/**/*.puml
```

## Status

- **Phase 0 (UML design baseline)** — complete. 5 packages of diagrams.
- **Phase 1 (provisioning: NFS, packages, Ansible)** — partial. Custom
  stage and Ansible playbooks are in place; smoke tests pending.
- **Phase 2 (image bake)** — works on Apple Silicon via Podman machine.
- **Phase 3 (Slurm + sphinx-asr integration)** — not started. Planned:
  a `Queue::Slurm` Perl adapter (~150 lines) sitting alongside
  SphinxTrain's existing `Queue::PBS`, plus an `sbatch --array` decode
  path driven from Python. Design lives in
  [`docs/uml/04-slurm-integration/`](docs/uml/04-slurm-integration/).

## Submodules

Two submodules carry the heavy lifting:

- **`pi-gen/`** — RPi-Distro's official pi-gen, Apache 2.0. The image
  builder.
- **`sphinx-asr/`** — Mason Armand's CMU Sphinx training/decoding
  toolchain, zlib license. The ASR workload.

Both are tracked at fixed commits via the submodule pointer mechanism.
Changes to those upstream projects land in their own repos first;
this repo only bumps the submodule pointer. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the bump protocol.

## License

MIT — see [LICENSE](LICENSE). Submodule code is governed by its own
license (`pi-gen` Apache 2.0; `sphinx-asr` zlib).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch model, commit
conventions, submodule discipline, and house style. The build is
intentionally airgap-at-runtime — please don't add anything that
requires a network call after firstboot.
