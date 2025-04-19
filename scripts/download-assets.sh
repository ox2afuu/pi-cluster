#!/usr/bin/env bash
#
# download-assets.sh — fetch the airgap k3s payload.
#
# Run this once while the MacBook has internet. Re-running is a no-op as long
# as the files already exist with non-zero size (idempotent). Delete a file in
# assets/ to force re-download.
#
set -euo pipefail

# Pinned k3s release. Bump this when you explicitly want a newer server/agent.
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"

# Resolve paths relative to repo root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"

mkdir -p "${ASSETS_DIR}"

fetch() {
  local url="$1"
  local out="$2"
  if [[ -s "${out}" ]]; then
    echo "[skip] ${out##*/} already present"
    return 0
  fi
  echo "[get]  ${url}"
  curl --fail --location --show-error --retry 3 --retry-delay 2 \
    --output "${out}" "${url}"
}

fetch "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64" \
      "${ASSETS_DIR}/k3s"

fetch "https://get.k3s.io" \
      "${ASSETS_DIR}/k3s-install.sh"

fetch "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-arm64.tar.zst" \
      "${ASSETS_DIR}/k3s-airgap-images-arm64.tar.zst"

fetch "https://github.com/ohmyzsh/ohmyzsh/archive/refs/heads/master.tar.gz" \
      "${ASSETS_DIR}/ohmyzsh.tar.gz"

chmod 0755 "${ASSETS_DIR}/k3s" "${ASSETS_DIR}/k3s-install.sh"

# Record which version we pulled so rebuilds are traceable.
echo "${K3S_VERSION}" > "${ASSETS_DIR}/K3S_VERSION"

echo
echo "Assets ready in ${ASSETS_DIR} (k3s ${K3S_VERSION}, oh-my-zsh tarball)."
