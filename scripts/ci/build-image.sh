#!/usr/bin/env bash
#
# scripts/ci/build-image.sh
#
# Linux-native image build for CI. Runs on the `pigen-builder` GitLab
# runner (Debian 13 arm64 Lima VM, shell executor, passwordless sudo); see
# docs/infra/gitlab-ci.md. The macOS operator path is still
# scripts/build.sh, which runs pi-gen inside podman. This script runs
# pi-gen directly on the arm64 host, so no container and no qemu.
#
# Usage:
#   scripts/ci/build-image.sh
#
# What it does:
#   1. Checks the host (aarch64, sudo, tools) and that pi-gen builds arm64.
#   2. Initialises submodules and fails if pi-gen or sphinx-asr is
#      uninitialised, off its pinned commit, or has local changes.
#   3. Generates EPHEMERAL secrets (munge key, cluster SSH key, k3s token)
#      with scripts/generate-*.sh, downloads assets with
#      scripts/download-assets.sh, and deletes the secrets again on exit.
#   4. Exports pi-gen (git archive) into a scratch directory outside the
#      checkout and applies the same adjustments as scripts/build.sh and
#      scripts/_pigen-podman.sh there (SKIP markers on stage3-5, no stage2
#      export, losetup -f sanitising). The submodule itself is never
#      modified, and root-owned build files never land in the checkout.
#   5. Runs pi-gen's build.sh -c configs/config.base as root via sudo.
#   6. Writes to OUT_DIR: the xz-compressed image, image-manifest.json
#      (repo, submodule and input-asset hashes, image hashes, pi-gen
#      version), the in-image sphinx-asr manifest, pi-gen's build.log and
#      package list, and SHA256SUMS.
#
# The image keeps configs/config.base's FIRST_USER_PASS and
# PUBKEY_ONLY_SSH=0 (review finding IC-4, open). Together with the baked
# ephemeral keys this makes every CI image and artifact secret.
#
# Environment (all optional):
#   OUT_DIR                  output directory (default: <repo>/out)
#   IVALICE_CI_WORK_ROOT     scratch root for pi-gen work trees
#                            (default: /var/tmp/ivalice-ci)
#   IVALICE_PUBKEY_PATH      operator SSH public key file; a GitLab "File"
#                            CI variable works as is
#   IVALICE_OPERATOR_PUBKEY  operator SSH public key as text, used when
#                            IVALICE_PUBKEY_PATH is unset
#   IVALICE_REQUIRE_OPERATOR_KEY=1
#                            fail instead of warning when neither is set
#                            (the image then trusts only the ephemeral
#                            cluster key)
#   IVALICE_KEEP_WORK=1      keep the pi-gen work tree for triage
#   IVALICE_FORCE_EPHEMERAL=1
#                            outside CI, allow replacing existing secrets in
#                            assets/ (they are deleted on exit)
#   IVALICE_XZ_LEVEL         xz preset (default: 6)
#   CI_*                     GitLab predefined variables, recorded in the
#                            manifest when present
#
# Exit codes:
#   0  image built; outputs in OUT_DIR
#   1  build failure (pi-gen, asset download or secret generation failed)
#   2  host preflight failed (not aarch64, no sudo, missing tool, pi-gen
#      not on an arm64 commit, existing secrets outside CI, no operator
#      key while IVALICE_REQUIRE_OPERATOR_KEY=1)
#   3  a submodule is missing, off its pinned commit, or dirty
#   4  pi-gen finished but produced no single .img
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"
WORK_ROOT="${IVALICE_CI_WORK_ROOT:-/var/tmp/ivalice-ci}"
WORK="${WORK_ROOT}/${CI_JOB_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
XZ_LEVEL="${IVALICE_XZ_LEVEL:-6}"
ASSETS="${REPO_ROOT}/assets"
SECRET_FILES=(
  "${ASSETS}/munge.key"
  "${ASSETS}/ivalice-cluster"
  "${ASSETS}/ivalice-cluster.pub"
  "${ASSETS}/cluster-token"
)
OPERATOR_KEY_FILE=""
# Set to 1 only once this run has generated its own secrets; until then the
# cleanup trap must not touch assets/ (it may hold an operator's real keys).
OWN_SECRETS=0

log() { printf '==> %s\n' "$*"; }
die() { local code="$1"; shift; printf 'ERROR: %s\n' "$*" >&2; exit "${code}"; }

# --- cleanup: secrets always, work tree unless kept or still mounted --------
cleanup() {
  local rc=$?
  set +e
  if [ "${OWN_SECRETS}" = "1" ]; then
    rm -f "${SECRET_FILES[@]}"
  fi
  [ -n "${OPERATOR_KEY_FILE}" ] && rm -f "${OPERATOR_KEY_FILE}"

  if [ -d "${WORK}" ]; then
    # pi-gen's own EXIT trap unmounts on failure; this catches anything
    # left by a killed build. Deepest mount first, lazily.
    local m dev
    awk -v w="${WORK}/" 'index($2, w) == 1 {print $2}' /proc/self/mounts \
      | sort -r | while IFS= read -r m; do
        echo "cleanup: unmounting ${m}" >&2
        sudo umount -l "${m}"
      done
    sudo losetup -n -l -O NAME,BACK-FILE 2>/dev/null \
      | awk -v w="${WORK}/" 'index($2, w) == 1 {print $1}' \
      | while IFS= read -r dev; do
        echo "cleanup: detaching ${dev}" >&2
        sudo losetup -d "${dev}"
      done

    if awk -v w="${WORK}/" 'index($2, w) == 1 {found=1} END {exit !found}' /proc/self/mounts; then
      echo "WARNING: mounts remain under ${WORK}; leaving it in place" >&2
    elif [ "${IVALICE_KEEP_WORK:-0}" = "1" ]; then
      echo "Keeping work tree ${WORK} (IVALICE_KEEP_WORK=1)" >&2
    else
      sudo rm -rf --one-file-system "${WORK}"
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

cd "${REPO_ROOT}"

# --- 1. preflight -----------------------------------------------------------
log "preflight"
[ "$(uname -s)" = "Linux" ] || die 2 "this is the Linux CI path; on macOS use scripts/build.sh"
if [ "$(uname -m)" != "aarch64" ]; then
  die 2 "host is $(uname -m); the pigen-builder runner is native aarch64 so pi-gen needs no qemu"
fi
for tool in git sudo jq xz sha256sum ssh-keygen openssl curl tar awk; do
  command -v "${tool}" >/dev/null 2>&1 || die 2 "missing tool: ${tool}"
done
sudo -n true 2>/dev/null || die 2 "passwordless sudo is required (pi-gen runs as root)"

# GITLAB_CI (not the generic CI) so a stray CI=true in an operator shell
# cannot wipe real keys; a GitLab job always starts from a fresh clone.
if [ "${GITLAB_CI:-}" != "true" ] && [ "${IVALICE_FORCE_EPHEMERAL:-0}" != "1" ]; then
  for f in "${SECRET_FILES[@]}"; do
    if [ -e "${f}" ]; then
      die 2 "${f} exists; this script replaces and then deletes assets/ secrets. Use a scratch clone or set IVALICE_FORCE_EPHEMERAL=1."
    fi
  done
fi

# --- 2. submodules ----------------------------------------------------------
log "submodules"
git submodule sync --recursive >/dev/null
git submodule update --init --recursive
while IFS= read -r line; do
  case "${line:0:1}" in
    " ") ;;
    *) die 3 "submodule not at its pinned commit or not initialised: ${line}" ;;
  esac
done < <(git submodule status --recursive)
for sm in pi-gen sphinx-asr; do
  [ -e "${sm}/.git" ] || die 3 "submodule ${sm} is missing"
  if [ -n "$(git -C "${sm}" status --porcelain)" ]; then
    git -C "${sm}" status --short >&2
    die 3 "submodule ${sm} has local changes"
  fi
done

PIGEN_ARCH="$(sed -n 's/^export ARCH=\(.*\)$/\1/p' pi-gen/build.sh | head -n 1)"
[ "${PIGEN_ARCH}" = "arm64" ] || die 2 "pi-gen pin builds '${PIGEN_ARCH}', expected arm64 (pin pi-gen to its arm64 branch)"

REPO_SHA="$(git rev-parse HEAD)"
REPO_BRANCH="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
PIGEN_SHA="$(git -C pi-gen rev-parse HEAD)"
PIGEN_DESCRIBE="$(git -C pi-gen describe --tags --always 2>/dev/null || echo "${PIGEN_SHA}")"
SPHINX_SHA="$(git -C sphinx-asr rev-parse HEAD)"
log "repo ${REPO_SHA} (${REPO_BRANCH}); pi-gen ${PIGEN_DESCRIBE}; sphinx-asr ${SPHINX_SHA}"

# --- 3. ephemeral secrets and assets ------------------------------------------
log "ephemeral secrets and airgap assets"
OWN_SECRETS=1
rm -f "${SECRET_FILES[@]}"
./scripts/generate-token.sh
./scripts/generate-ssh-key.sh
./scripts/generate-munge-key.sh
./scripts/download-assets.sh

# Operator key first, then the cluster key, newline-separated: the same
# shape scripts/build.sh exports.
operator_key_source="none"
if [ -n "${IVALICE_PUBKEY_PATH:-}" ]; then
  [ -s "${IVALICE_PUBKEY_PATH}" ] || die 2 "IVALICE_PUBKEY_PATH=${IVALICE_PUBKEY_PATH} is not a readable key file"
  operator_key="$(cat "${IVALICE_PUBKEY_PATH}")"
  operator_key_source="IVALICE_PUBKEY_PATH"
elif [ -n "${IVALICE_OPERATOR_PUBKEY:-}" ]; then
  operator_key="${IVALICE_OPERATOR_PUBKEY}"
  operator_key_source="IVALICE_OPERATOR_PUBKEY"
else
  operator_key=""
fi
if [ -n "${operator_key}" ]; then
  OPERATOR_KEY_FILE="$(mktemp)"
  printf '%s\n' "${operator_key}" > "${OPERATOR_KEY_FILE}"
  ssh-keygen -l -f "${OPERATOR_KEY_FILE}" >/dev/null 2>&1 \
    || die 2 "operator key from ${operator_key_source} is not a valid SSH public key"
  PUBKEY_SSH_FIRST_USER="${operator_key}
$(cat "${ASSETS}/ivalice-cluster.pub")"
else
  if [ "${IVALICE_REQUIRE_OPERATOR_KEY:-0}" = "1" ]; then
    die 2 "no operator key: set IVALICE_PUBKEY_PATH or IVALICE_OPERATOR_PUBKEY"
  fi
  echo "WARNING: no operator SSH key (IVALICE_PUBKEY_PATH / IVALICE_OPERATOR_PUBKEY);" >&2
  echo "         the image trusts only the ephemeral cluster key." >&2
  PUBKEY_SSH_FIRST_USER="$(cat "${ASSETS}/ivalice-cluster.pub")"
fi

# --- 4. scratch pi-gen with the build.sh / _pigen-podman.sh adjustments -----
log "pi-gen work tree ${WORK}"
mkdir -p "${WORK}/pi-gen"
git -C pi-gen archive --format=tar HEAD | tar -x -C "${WORK}/pi-gen"
# config.base sets STAGE_LIST="... ../stages/stage-ivalice-base", relative
# to pi-gen; the stage then finds the assets at ${STAGE_DIR}/../../assets.
ln -s "${REPO_ROOT}/stages" "${WORK}/stages"

# Reuse the podman wrapper's patch functions against the scratch copy.
# shellcheck source=scripts/_pigen-podman.sh
. "${REPO_ROOT}/scripts/_pigen-podman.sh"
PI_GEN_DIR="${WORK}/pi-gen"
patch_pigen_losetup_sanitize
remove_pigen_stage2_export_marker
for s in stage3 stage4 stage5; do
  touch "${PI_GEN_DIR}/${s}/SKIP" "${PI_GEN_DIR}/${s}/SKIP_IMAGES"
done

# --- 5. pi-gen ------------------------------------------------------------
log "pi-gen build.sh -c configs/config.base (as root)"
build_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  cd "${PI_GEN_DIR}"
  sudo env \
    PUBKEY_SSH_FIRST_USER="${PUBKEY_SSH_FIRST_USER}" \
    GIT_HASH="${REPO_SHA}" \
    IVALICE_REPO_ROOT="${REPO_ROOT}" \
    WORK_DIR="${WORK}/work/ivalice" \
    DEPLOY_DIR="${WORK}/deploy" \
    ./build.sh -c "${REPO_ROOT}/configs/config.base"
) || die 1 "pi-gen build failed (log: ${WORK}/work/ivalice/build.log)"
build_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 6. outputs ---------------------------------------------------------------
log "collecting outputs into ${OUT_DIR}"
sudo chown -R "$(id -u):$(id -g)" "${WORK}/deploy"
mapfile -t imgs < <(find "${WORK}/deploy" -maxdepth 1 -name '*.img' -type f)
[ "${#imgs[@]}" -eq 1 ] || die 4 "expected one .img in ${WORK}/deploy, found ${#imgs[@]}"
img="${imgs[0]}"
img_name="$(basename "${img}")"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
img_sha="$(sha256sum "${img}" | awk '{print $1}')"
img_bytes="$(stat -c %s "${img}")"
xz -T0 -"${XZ_LEVEL}" -c "${img}" > "${OUT_DIR}/${img_name}.xz"
xz_sha="$(sha256sum "${OUT_DIR}/${img_name}.xz" | awk '{print $1}')"
xz_bytes="$(stat -c %s "${OUT_DIR}/${img_name}.xz")"

# pi-gen's package list (.info) and anything else it deployed, minus images.
find "${WORK}/deploy" -maxdepth 1 -type f ! -name '*.img' -exec cp -t "${OUT_DIR}/" {} +
# sudo only reads the root-owned files; the copies belong to the runner user.
# shellcheck disable=SC2024
sudo cat "${WORK}/work/ivalice/build.log" > "${OUT_DIR}/build.log" 2>/dev/null || true
# shellcheck disable=SC2024
sudo cat "${WORK}/work/ivalice/stage-ivalice-base/rootfs/srv/ivalice/sphinx-asr/IMAGE-MANIFEST.txt" \
  > "${OUT_DIR}/sphinx-asr-IMAGE-MANIFEST.txt"

# sha256 of every build input: the config and each file in assets/.
inputs_json="$(
  {
    sha256sum configs/config.base
    find assets -maxdepth 1 -type f ! -name README.md ! -name .gitkeep -print0 \
      | sort -z | xargs -0 sha256sum
  } | jq -R -s 'split("\n") | map(select(length > 0) | capture("^(?<sha>[0-9a-f]{64})  (?<path>.+)$")) | map({(.path): .sha}) | add'
)"

jq -n \
  --arg built_at "${build_end}" \
  --arg build_started "${build_start}" \
  --arg repo_sha "${REPO_SHA}" \
  --arg branch "${REPO_BRANCH}" \
  --arg tag "${CI_COMMIT_TAG:-}" \
  --arg pipeline_id "${CI_PIPELINE_ID:-}" \
  --arg job_id "${CI_JOB_ID:-}" \
  --arg job_url "${CI_JOB_URL:-}" \
  --arg runner "${CI_RUNNER_DESCRIPTION:-$(hostname)}" \
  --arg pigen_sha "${PIGEN_SHA}" \
  --arg pigen_describe "${PIGEN_DESCRIBE}" \
  --arg pigen_arch "${PIGEN_ARCH}" \
  --arg sphinx_sha "${SPHINX_SHA}" \
  --arg k3s_version "$(cat assets/K3S_VERSION 2>/dev/null || true)" \
  --arg operator_key "${operator_key_source}" \
  --arg img_name "${img_name}" \
  --arg img_sha "${img_sha}" \
  --argjson img_bytes "${img_bytes}" \
  --arg xz_name "${img_name}.xz" \
  --arg xz_sha "${xz_sha}" \
  --argjson xz_bytes "${xz_bytes}" \
  --argjson inputs "${inputs_json}" \
  '{
    schema: 1,
    built_at: $built_at,
    build_started: $build_started,
    repo: {sha: $repo_sha, branch: $branch, tag: $tag},
    ci: {pipeline_id: $pipeline_id, job_id: $job_id, job_url: $job_url, runner: $runner},
    pi_gen: {sha: $pigen_sha, version: $pigen_describe, arch: $pigen_arch},
    submodules: {"pi-gen": $pigen_sha, "sphinx-asr": $sphinx_sha},
    config: "configs/config.base",
    k3s_version: $k3s_version,
    operator_pubkey_source: $operator_key,
    secrets: "ephemeral; generated for this build and baked into the image",
    inputs_sha256: $inputs,
    image: {file: $img_name, sha256: $img_sha, bytes: $img_bytes},
    artifact: {file: $xz_name, sha256: $xz_sha, bytes: $xz_bytes, compression: "xz"}
  }' > "${OUT_DIR}/image-manifest.json"

(
  cd "${OUT_DIR}"
  sums="$(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort \
    | xargs -d '\n' sha256sum)"
  printf '%s\n' "${sums}" > SHA256SUMS
)

if [ "${xz_bytes}" -gt $((1000 * 1024 * 1024)) ]; then
  echo "WARNING: ${img_name}.xz is $((xz_bytes / 1024 / 1024)) MiB; GitLab's artifact" >&2
  echo "         size limit (max_artifacts_size) may reject the upload." >&2
fi

log "done"
ls -l "${OUT_DIR}"
