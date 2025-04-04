#!/usr/bin/env bash
#
# generate-token.sh — create the shared k3s cluster token once.
#
# This single token is baked into both the head image (written to
# /var/lib/rancher/k3s/server/token) and every worker image (written to
# /etc/rancher/k3s/config.yaml). Workers auto-join on first boot.
#
# Idempotent: re-running does nothing if assets/cluster-token already exists.
# Delete the file by hand if you ever need a fresh token (and then rebuild
# every image).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="${REPO_ROOT}/assets/cluster-token"

mkdir -p "${REPO_ROOT}/assets"

if [[ -s "${TOKEN_FILE}" ]]; then
  echo "[skip] ${TOKEN_FILE} already exists"
  exit 0
fi

# 64 hex chars = 32 bytes of entropy, well above k3s requirements.
openssl rand -hex 32 > "${TOKEN_FILE}"
chmod 0600 "${TOKEN_FILE}"

echo "Wrote new cluster token to ${TOKEN_FILE}"
