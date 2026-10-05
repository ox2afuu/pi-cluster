#!/usr/bin/env bash
# scripts/ci/store-image.sh
#
# Move the built image out of the job's artifacts and into a store on the
# pigen-builder runner, leaving a pointer in out/IMAGE_PATH.
#
# The compressed image (about 1.1 GiB) is larger than GitLab's
# max_artifacts_size, and build-image and verify-image both run on the same
# dedicated runner, so the image never needs to travel through GitLab.
# Artifacts keep only the small files (manifests, checksums, logs).
#
# Usage:
#   scripts/ci/store-image.sh [OUT_DIR]      (default OUT_DIR: out)
#
# Environment:
#   IVALICE_IMAGE_STORE  store root            (default /var/lib/ivalice-images)
#   IVALICE_IMAGE_KEEP   builds to keep        (default 5; older ones pruned)
#   CI_PIPELINE_ID       store subdirectory    (default: local-<epoch>)
#
# Exit codes:
#   0  image stored and pointer written
#   1  no image found in OUT_DIR, or the store could not be written
set -euo pipefail

OUT_DIR="${1:-out}"
STORE="${IVALICE_IMAGE_STORE:-/var/lib/ivalice-images}"
KEEP="${IVALICE_IMAGE_KEEP:-5}"
DEST="${STORE}/${CI_PIPELINE_ID:-local-$(date +%s)}"

shopt -s nullglob
images=("${OUT_DIR}"/*.img.xz)
if [ "${#images[@]}" -ne 1 ]; then
  echo "error: expected exactly one ${OUT_DIR}/*.img.xz, found ${#images[@]}" >&2
  exit 1
fi

sudo install -d -m 0750 -o "$(id -u)" -g "$(id -g)" "${STORE}"
install -d -m 0750 "${DEST}"
mv "${images[0]}" "${DEST}/"
cp "${OUT_DIR}/SHA256SUMS" "${OUT_DIR}/image-manifest.json" "${DEST}/" 2>/dev/null || true
printf '%s\n' "${DEST}/$(basename "${images[0]}")" > "${OUT_DIR}/IMAGE_PATH"
echo "==> stored $(cat "${OUT_DIR}/IMAGE_PATH")"

# Keep the newest KEEP builds (by mtime); the store holds secrets-bearing
# images, so old ones should not pile up.
mapfile -t old < <(find "${STORE}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2-)
for d in "${old[@]}"; do
  echo "==> pruning ${d}"
  rm -rf -- "${d}"
done
