#!/usr/bin/env bash
# scripts/generate-munge-key.sh
# Generates the shared munge key for Slurm auth. Idempotent — skip if present.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_FILE="${REPO_ROOT}/assets/munge.key"

mkdir -p "${REPO_ROOT}/assets"

if [[ -s "${KEY_FILE}" ]]; then
  echo "[skip] ${KEY_FILE} already exists"
  exit 0
fi

dd if=/dev/urandom bs=1 count=1024 of="${KEY_FILE}" status=none
chmod 0400 "${KEY_FILE}"

echo "Wrote ${KEY_FILE}"
