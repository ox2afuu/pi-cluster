#!/bin/bash -e
# stage-ivalice-base/10-sphinx-asr/00-run.sh
#
# Host side, before the chroot build. Exports the pinned sphinx-asr
# submodule commit into ${ROOTFS_DIR}/srv/ivalice/sphinx-asr with
# `git archive` (no .git, no untracked files, no build products), and
# gives the chroot working DNS for the venv's pip install.
#
# The image must contain exactly the commit the superproject pins, so this
# fails when the submodule is missing, has tracked changes, or has a HEAD
# that differs from the recorded gitlink.
#
# Repo root: IVALICE_REPO_ROOT when set (scripts/_pigen-podman.sh mounts
# the repo at /ivalice-repo and sets it; scripts/ci/build-image.sh exports
# the checkout path). Otherwise the parent of stages/, which is right for
# any native build that runs pi-gen against this checkout.
set -euo pipefail

REPO="${IVALICE_REPO_ROOT:-$(realpath "${STAGE_DIR}/../..")}"
SUB="${REPO}/sphinx-asr"
DEST="${ROOTFS_DIR}/srv/ivalice/sphinx-asr"

# The repo is owned by the operator (podman bind mount) or by gitlab-runner
# (CI), while this runs as root. Mark it safe for these calls only, and
# never take optional locks, because the podman mount is read-only.
git_ro() { git -c safe.directory='*' --no-optional-locks "$@"; }

if [ ! -e "${SUB}/.git" ]; then
  echo "ERROR: ${SUB} is not a checked-out submodule; run" >&2
  echo "       git submodule update --init --recursive" >&2
  exit 1
fi

sha="$(git_ro -C "${SUB}" rev-parse HEAD)"
pinned="$(git_ro -C "${REPO}" ls-files --stage -- sphinx-asr | awk '$1 == "160000" {print $2}')"
if [ -z "${pinned}" ]; then
  echo "ERROR: ${REPO} records no gitlink for sphinx-asr" >&2
  exit 1
fi
if [ "${sha}" != "${pinned}" ]; then
  echo "ERROR: sphinx-asr HEAD ${sha} differs from the pinned ${pinned}." >&2
  echo "       Run 'git submodule update' or commit the pointer bump first." >&2
  exit 1
fi
dirty="$(git_ro -C "${SUB}" status --porcelain --untracked-files=no)"
if [ -n "${dirty}" ]; then
  echo "ERROR: sphinx-asr has uncommitted changes; the image would not match ${sha}:" >&2
  printf '%s\n' "${dirty}" >&2
  exit 1
fi

# Re-runs of this stage (CLEAN=0) start from a fresh export.
rm -rf "${DEST}"
install -d -m 0755 "${ROOTFS_DIR}/srv/ivalice" "${DEST}"
git_ro -C "${SUB}" archive --format=tar "${sha}" | tar -x -C "${DEST}"

# The submodule tree commits x86 objects under vendor/cmu_toolkit/src
# (*.o, and SLM2.a once built). `make clean` does not remove them, and
# linking them on aarch64 fails with "file in wrong format", so drop every
# prebuilt object before the chroot build.
find "${DEST}/vendor" -type f \( -name '*.o' -o -name '*.a' \) -delete

# Header of the in-image manifest. 01-run-chroot.sh and 02-run.sh append.
cat > "${DEST}/IMAGE-MANIFEST.txt" <<EOF
# sphinx-asr build manifest, written by stages/stage-ivalice-base/10-sphinx-asr
sphinx_asr_commit: ${sha}
sphinx_asr_source: git archive of the pinned submodule commit
image_git_hash: ${GIT_HASH:-unknown}
build_date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# on_chroot mounts a fresh tmpfs on /run, so the stub-resolv.conf symlink
# that 00-ivalice-base points /etc/resolv.conf at dangles inside the
# chroot. Use the build host's resolver for pip, and let 02-run.sh put
# the symlink back.
RESOLV="${ROOTFS_DIR}/etc/resolv.conf"
if [ -L "${RESOLV}" ]; then
  readlink "${RESOLV}" > "${ROOTFS_DIR}/etc/.ivalice-resolv-link"
fi
host_resolv=/etc/resolv.conf
if [ -s /run/systemd/resolve/resolv.conf ]; then
  # On a systemd-resolved host, /etc/resolv.conf names 127.0.0.53, which
  # works in the chroot too, but the upstream list does not depend on it.
  host_resolv=/run/systemd/resolve/resolv.conf
fi
rm -f "${RESOLV}"
cp -L "${host_resolv}" "${RESOLV}"
