# 0002: A dedicated Lima VM runner for image builds

- **Status:** Proposed
- **Date:** 2026-10-05
- **Deciders:** ivaliceCluster maintainer

## Context

The image has only ever been built by hand on the operator's Mac, through
`scripts/build.sh` and the Podman wrapper `scripts/_pigen-podman.sh`.
Nothing checks a change to `stages/` or bumps of the `pi-gen` and
`sphinx-asr` submodules before someone flashes a CM4, and no build record
says which inputs went into an image (review finding IC-9).

pi-gen has to run as root. It debootstraps a rootfs, bind-mounts `/proc`,
`/dev` and `/sys` into chroots, and partitions and formats a loop device.
The project's GitLab instance already has one shared runner, `mac-local`:
a Docker executor backed by rootless, unprivileged Podman in a Lima VM
with 2 GB of RAM, serving other projects too. It cannot attach loop
devices, and making it privileged would give every project root on that
VM.

The cluster is aarch64 only (CM4), and the Mac is an Apple Silicon
machine, so an arm64 Linux VM under Virtualization.framework runs pi-gen's
arm64 build natively, with no qemu-user emulation.

## Decision

We will build and verify images in CI on a dedicated Debian 13 arm64 Lima
VM, `pigen-builder` (8 CPU, 16 GB, 120 GB), registered as a project runner
for `unh/pi-cluster` with the shell executor, tags `pigen` and `aarch64`,
`run_untagged=false` and `concurrent=1`. Its `gitlab-runner` user has
passwordless sudo, and pi-gen runs on the VM directly through
`scripts/ci/build-image.sh`. Lint and unit tests stay on `mac-local`.

## Alternatives considered

| Option | Why not |
| --- | --- |
| Privileged Docker jobs on `mac-local` | Grants root and loop devices to every project that uses the shared runner; 2 GB of RAM is too little for pi-gen plus the vendor build |
| The operator's Podman machine as a runner | Couples CI to the workstation's Podman state (the loop-device cleanup in `scripts/_pigen-podman.sh` exists because of it) and blocks the operator's own builds |
| An x86_64 runner with qemu-user | Emulated arm64 chroots make the sphinx-asr vendor build and apt slow, and binfmt setup is fragile (pi-gen arm64 now tests for it in an empty chroot) |
| Building on a CM4 | Hours per image, and ties up cluster hardware |
| Hosted CI (GitHub Actions arm64) | The image carries cluster secrets (munge key, k3s token, SSH key) and the IC-4 default password; images must not leave the operator's machines |

## Consequences

- Every push to `main`, every tag and every schedule builds and verifies an
  image automatically; merge requests and other branches can build on
  demand. Each image ships with a manifest of input and output hashes.
- The CI path does not reuse the Podman wrapper, so there are two build
  entry points to keep in step. `scripts/ci/build-image.sh` sources the
  wrapper's pi-gen patch functions so the adjustments live in one place.
- The VM is a privileged build host: anyone who can push a branch can run
  root code on it through a manual job. It must stay a project runner
  (locked to this project) and have no host mounts.
- CI images hold ephemeral secrets and the IC-4 default password, so the
  artifacts are secret, expire after a week, and must never be published.
- Follow-up: raise GitLab's 1024 MB artifact limit if compressed images
  approach it, and close IC-4 so CI images stop carrying a published
  password.
