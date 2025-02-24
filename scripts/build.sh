#!/usr/bin/env bash
# scripts/build.sh
# Builds the unified Ivalice pi-gen image. Idempotent for downloads/assets.
set -euo pipefail

. "$(dirname "$0")/_pigen-podman.sh"

cd "${REPO_ROOT}"

./scripts/download-assets.sh
./scripts/generate-token.sh
./scripts/generate-ssh-key.sh
./scripts/generate-munge-key.sh

# --- resolve SSH pubkeys on the host --------------------------------------
# The build container has no access to the operator's ~/.ssh/, so we read the
# operator pubkey (default ~/.ssh/headnode-key.pub, override via
# IVALICE_PUBKEY_PATH) and the cluster pubkey here on the host, concatenate
# them with a literal newline, and forward the result as an env var into the
# pi-gen container (see _pigen-podman.sh).
_pubkey_path="${IVALICE_PUBKEY_PATH:-${HOME}/.ssh/headnode-key.pub}"
if [[ ! -f "${_pubkey_path}" ]]; then
  echo "ERROR: operator pubkey ${_pubkey_path} not found; refusing to build." >&2
  echo "       Set IVALICE_PUBKEY_PATH or place your pubkey there." >&2
  exit 1
fi

_cluster_pub="${REPO_ROOT}/assets/ivalice-cluster.pub"
if [[ ! -f "${_cluster_pub}" ]]; then
  echo "ERROR: ${_cluster_pub} missing; generate-ssh-key.sh should have created it." >&2
  exit 1
fi

# Literal newline between the two keys — pi-gen splits authorized_keys on \n.
export PUBKEY_SSH_FIRST_USER="$(cat "${_pubkey_path}")
$(cat "${_cluster_pub}")"

# --- tell pi-gen to skip the upstream desktop stages ---------------------
for s in stage3 stage4 stage5; do
  touch "pi-gen/${s}/SKIP" "pi-gen/${s}/SKIP_IMAGES"
done

run_pigen "${REPO_ROOT}/configs/config.base"
