#!/usr/bin/env bash
#
# scripts/_pigen-podman.sh
#
# Internal helper sourced by scripts/build-{head,head-gui,worker}.sh.
# Builds and runs pi-gen inside podman, replacing pi-gen's stock
# build-docker.sh. We don't use build-docker.sh directly because:
#
#   1. It greps `podman info` for the substring "rootless" and prepends
#      `sudo` if found. Even in *rootful* podman that string still appears
#      in the info output, so the check misfires. And `sudo podman` on macOS
#      runs against a different (root) socket than the user's podman machine,
#      so the build never reaches the VM.
#
#   2. It bind-mounts only the config file. Our pi-gen stages and airgap
#      assets live OUTSIDE the pi-gen tree (under ../stages and ../assets),
#      and pi-gen's Dockerfile bakes only the pi-gen directory into the image
#      via COPY. Without extra bind-mounts the external stages aren't visible
#      to the build at all.
#
# This helper:
#   - Verifies a rootful podman machine is running.
#   - Builds the pi-gen container image (`podman build`).
#   - Runs the build with --privileged plus three bind-mounts:
#       /config   ← the per-image config file
#       /stages   ← ${REPO_ROOT}/stages   (so STAGE_LIST=../stages/* works)
#       /assets   ← ${REPO_ROOT}/assets   (so ${STAGE_DIR}/../../assets works)
#   - Copies the contents of /pi-gen/deploy out of the container into
#     pi-gen/deploy/ on the host (images only), and dumps the container log
#     to pi-gen/logs/build-podman.log.
#   - Removes the work container unless PRESERVE_CONTAINER=1.

set -euo pipefail

# Repo root: parent of this script's directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_GEN_DIR="${REPO_ROOT}/pi-gen"

require_podman_machine() {
  if ! command -v podman >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: podman is not installed.
On macOS:
  brew install podman
  podman machine init --rootful --cpus 4 --memory 8192 --disk-size 64
  podman machine start
EOF
    exit 1
  fi

  if ! podman info >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: podman is installed but not responding. On macOS the podman machine
must be initialized and started:
  podman machine init --rootful --cpus 4 --memory 8192 --disk-size 64
  podman machine start
EOF
    exit 1
  fi

  # Skip the rootful check on Linux (not needed) — only enforce on macOS.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi

  # `podman machine inspect` returns JSON; look for "Rootful": true on the
  # active machine. If jq isn't available, fall back to a grep.
  local rootful
  if command -v jq >/dev/null 2>&1; then
    rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null | head -n1 || true)"
  else
    rootful="$(podman machine inspect 2>/dev/null | grep -o '"Rootful": *true' | head -n1 || true)"
    [[ -n "${rootful}" ]] && rootful="true"
  fi

  if [[ "${rootful}" != "true" ]]; then
    cat >&2 <<'EOF'
ERROR: the active podman machine is rootless. pi-gen needs rootful mode for
mount/chroot operations during the image build. Switch with:
  podman machine stop
  podman machine set --rootful
  podman machine start
EOF
    exit 1
  fi
}

# Put the podman VM kernel into a known-good state before we build.
#
# The only known-bad state that actually bites us today is stale loop
# devices: the podman VM kernel persists across container lifetimes, and
# a previous (possibly crashed) build can leave loop devices attached to
# backing files that no longer exist. Those show up in losetup output as
# "/dev/loopN (lost)" or "/dev/loopN ... (deleted)". pi-gen's
# export-image/prerun.sh calls `losetup -f` to pick the next free loop and
# passes that string to mknod; the " (lost)" suffix crashes mknod with
# "invalid minor device number" and the build dies.
#
# `losetup -D` alone does NOT reliably clear "(lost)"/"(deleted)" entries
# on the kernels podman-machine ships, so we iterate and detach each
# stale device by hand.
#
# On Darwin we talk to the VM via `podman machine ssh`. On Linux the
# container shares the host kernel directly, and yanking loop devices on
# the user's host could unmount unrelated things (snap packages, mounted
# ISOs, etc.), so we skip and let the in-container safety net handle it.
ensure_clean_podman_state() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi

  echo "==> preflight: clearing stale loop devices in podman VM"
  if ! podman machine ssh '
    set -u
    sudo losetup -D 2>/dev/null || true
    (sudo losetup -a 2>/dev/null || true) | while IFS= read -r line; do
      case "$line" in
        *"(lost)"*|*"(deleted)"*)
          dev=${line%%:*}
          echo "  detaching stale loop $dev"
          sudo losetup -d "$dev" 2>/dev/null || true
          ;;
      esac
    done
    remaining=$(sudo losetup -a 2>/dev/null | wc -l | tr -d " ")
    echo "  attached loop devices after cleanup: ${remaining:-0}"
  '; then
    echo "WARNING: podman machine ssh failed during preflight; continuing" >&2
    echo "         (in-container cleanup will still run)" >&2
  fi
}

# Patch pi-gen/scripts/common so ensure_next_loopdev tolerates util-linux 2.41.
#
# Debian trixie ships util-linux 2.41, whose `losetup -f` annotates its output
# with " (lost)" or " (deleted)" when the next free loop slot's backing file
# has been unlinked. pi-gen's ensure_next_loopdev captures that string verbatim
# and passes it to mknod, which rejects it ("invalid minor device number") and
# crashes export-image/prerun.sh. No amount of pre-build loop cleanup fixes
# this because the annotation is emitted by losetup itself, not by a stale
# attachment we can detach.
#
# Fix: pipe `losetup -f` through awk to take only the first whitespace-
# separated field. Idempotent — skip if already applied, so re-runs and fresh
# clones both work. We patch before `podman build` so the fix gets baked into
# the container image via pi-gen's `COPY . /pi-gen/`.
patch_pigen_losetup_sanitize() {
  local common="${PI_GEN_DIR}/scripts/common"

  if [[ ! -f "${common}" ]]; then
    echo "WARNING: ${common} not found; skipping losetup-f sanitize patch" >&2
    return 0
  fi

  if grep -q 'losetup -f | awk' "${common}"; then
    echo "==> pi-gen/scripts/common already patched"
    return 0
  fi

  # Match the exact line as shipped: tab-indented, no trailing whitespace.
  # Using sed -i.bak for macOS/GNU portability, then removing the backup.
  # Delimiter is '#' because the replacement contains '|' (losetup -f | awk).
  sed -i.bak \
    's#^\(	\)loopdev="\$(losetup -f)"$#\1loopdev="$(losetup -f | awk '\''{print $1}'\'')"#' \
    "${common}"
  rm -f "${common}.bak"

  if ! grep -q 'losetup -f | awk' "${common}"; then
    echo "ERROR: sed did not apply the losetup-f sanitize patch to ${common}" >&2
    exit 1
  fi

  echo "==> patched pi-gen/scripts/common: strip util-linux 2.41 losetup-f suffix"
}

# Suppress pi-gen's stage2 "-lite" image export.
#
# pi-gen writes a .img for every stage directory that contains an
# EXPORT_IMAGE marker. Upstream ships one in stage2/ that produces a bare
# Raspberry Pi OS Lite image. We build on top of stage2 in
# stages/stage-ivalice-base, which has its own EXPORT_IMAGE — so by default
# deploy/ gets two images, and the stage2 "-lite" one has none of the cluster
# tooling (no k3s, Slurm, munge, etc.) and is just dead weight.
#
# Removing the marker skips ONLY the image export for stage2; the stage2
# rootfs still gets built and carried forward into stage-ivalice-base, which
# is what we actually flash. Idempotent, so re-runs and fresh clones both
# work.
remove_pigen_stage2_export_marker() {
  local marker="${PI_GEN_DIR}/stage2/EXPORT_IMAGE"

  if [[ ! -e "${marker}" ]]; then
    echo "==> pi-gen stage2 image export already suppressed"
    return 0
  fi

  rm -f "${marker}"
  echo "==> suppressed pi-gen stage2 image export (only ivalice image will ship)"
}

# run_pigen <abs-config-file>
#
# Builds and runs pi-gen against the given config file. The config file must
# be an absolute host path that podman can bind-mount into the container.
run_pigen() {
  local config_file="$1"

  if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: config file '${config_file}' not found" >&2
    exit 1
  fi
  # Resolve to absolute path so bind-mounting works regardless of cwd.
  config_file="$(cd "$(dirname "${config_file}")" && pwd)/$(basename "${config_file}")"

  if [[ ! -d "${PI_GEN_DIR}" ]]; then
    cat >&2 <<EOF
ERROR: ${PI_GEN_DIR} is missing. Clone it with:
  git clone -b arm64 https://github.com/RPi-Distro/pi-gen.git pi-gen
EOF
    exit 1
  fi

  require_podman_machine
  ensure_clean_podman_state
  patch_pigen_losetup_sanitize
  remove_pigen_stage2_export_marker

  local container_name="${CONTAINER_NAME:-pigen_work}"

  # Refuse to start on top of a previous container — just like build-docker.sh.
  if podman ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
    cat >&2 <<EOF
ERROR: container '${container_name}' already exists. Remove it first:
  podman rm -v ${container_name}
Or set CONTAINER_NAME=somethingelse to use a different name.
EOF
    exit 1
  fi

  # pi-gen records GIT_HASH in the image; we don't have a git repo, so make
  # a stable-ish stamp from the current UTC date.
  local git_hash="${GIT_HASH:-ivalice-$(date -u +%Y%m%dT%H%M%SZ)}"

  echo "==> podman build pi-gen container image"
  podman build --build-arg BASE_IMAGE=debian:trixie -t pi-gen "${PI_GEN_DIR}"

  echo "==> podman run pi-gen build (this takes a while)"
  # We deliberately mirror the inner shell command from build-docker.sh so the
  # build environment matches what pi-gen upstream expects.
  podman run \
    --name "${container_name}" \
    --privileged \
    ${PIGEN_PODMAN_OPTS:-} \
    --volume "${config_file}:/config:ro" \
    --volume "${REPO_ROOT}/stages:/stages:ro" \
    --volume "${REPO_ROOT}/assets:/assets:ro" \
    -e "GIT_HASH=${git_hash}" \
    -e PUBKEY_SSH_FIRST_USER \
    pi-gen \
    bash -e -o pipefail -c '
      dpkg-reconfigure qemu-user-binfmt
      mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc || true

      # Final-pass loop cleanup inside the privileged container, in case
      # something slipped past the preflight or a new stale loop appeared
      # between preflight and now. losetup -D does not reliably clear
      # "(lost)"/"(deleted)" entries, so iterate and detach explicitly.
      # Without this, losetup -f in pi-gen export-image/prerun.sh can
      # return "/dev/loopN (lost)" which then crashes mknod with
      # "invalid minor device number".
      losetup -D 2>/dev/null || true
      (losetup -a 2>/dev/null || true) | while IFS= read -r line; do
        case "$line" in
          *"(lost)"*|*"(deleted)"*)
            dev=${line%%:*}
            echo "detaching stale loop $dev"
            losetup -d "$dev" 2>/dev/null || true
            ;;
        esac
      done

      cd /pi-gen
      ./build.sh -c /config
      rsync -av work/*/build.log deploy/
    '

  echo "==> copying deploy/ artifacts out of container"
  mkdir -p "${PI_GEN_DIR}/deploy"
  # Trailing '/.' copies the CONTENTS of /pi-gen/deploy into the host
  # pi-gen/deploy/ rather than nesting as pi-gen/deploy/deploy. We used to pipe
  # through tar (`podman cp ... - | tar -xf -`) but that silently produced an
  # empty extract on macOS/podman-machine, leaving deploy/ empty despite a
  # successful build.
  podman cp "${container_name}:/pi-gen/deploy/." "${PI_GEN_DIR}/deploy/"

  echo "==> writing container log to logs/build-podman.log"
  mkdir -p "${PI_GEN_DIR}/logs"
  podman logs --timestamps "${container_name}" \
    >"${PI_GEN_DIR}/logs/build-podman.log" 2>&1 || true

  if ! compgen -G "${PI_GEN_DIR}/deploy/*.img" >/dev/null; then
    echo "ERROR: no .img landed in ${PI_GEN_DIR}/deploy/ — see logs/build-podman.log" >&2
    exit 1
  fi

  if [[ "${PRESERVE_CONTAINER:-0}" != "1" ]]; then
    podman rm -v "${container_name}" >/dev/null
  fi

  echo
  echo "Done. Images are in ${PI_GEN_DIR}/deploy/"
  ls -lh "${PI_GEN_DIR}/deploy/" | tail -n 20
}
