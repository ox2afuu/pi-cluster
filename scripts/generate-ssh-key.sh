#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${REPO_ROOT}/assets/ivalice-cluster"

mkdir -p "${REPO_ROOT}/assets"

if [[ -s "${KEY}" && -s "${KEY}.pub" ]]; then
  echo "[skip] ${KEY} already exists"
  exit 0
fi

ssh-keygen -t ed25519 -N '' -C "ivalice-cluster" -f "${KEY}"
chmod 0600 "${KEY}"
chmod 0644 "${KEY}.pub"

echo "Wrote ${KEY} and ${KEY}.pub"
