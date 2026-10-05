#!/usr/bin/env bash
# baselines/rhel6/fetch-image.sh
# Download the pinned CentOS 6.10 GenericCloud qcow2 into .cache/ and verify
# it twice: against the sha256sum.txt published next to it, and against the
# hash hard-coded in _common.sh. A mismatch with either aborts.
#
# It then fetches every pinned dependency listed in deps.lock (cmake binary,
# Python source, offline wheelhouse) into .cache/ and verifies each sha256.
#
# Usage: ./fetch-image.sh
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

mkdir -p "${CACHE_DIR}"

published_sums="${CACHE_DIR}/sha256sum.txt"
log "fetching published checksums"
curl -fsSL --retry 3 -o "${published_sums}" "${IMAGE_URL_BASE}/sha256sum.txt"
published_hash="$(awk -v f="${IMAGE_NAME}" '$2 == f {print $1}' "${published_sums}")"
[[ -n "${published_hash}" ]] || die "${IMAGE_NAME} not listed in published sha256sum.txt"
[[ "${published_hash}" == "${IMAGE_SHA256}" ]] \
  || die "published hash ${published_hash} differs from pinned ${IMAGE_SHA256}"

# fetch_verified DEST SHA256 URL: download unless DEST already matches.
fetch_verified() {
  local dest="$1" want="$2" url="$3" got
  if [[ -f "${dest}" ]] && [[ "$(sha256_of "${dest}")" == "${want}" ]]; then
    log "cached, verified: ${dest#"${CACHE_DIR}"/}"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  log "downloading ${url}"
  curl -fL --retry 3 -C - -o "${dest}.part" "${url}"
  got="$(sha256_of "${dest}.part")"
  if [[ "${got}" != "${want}" ]]; then
    rm -f "${dest}.part"
    die "sha256 mismatch for ${dest}: got ${got}, expected ${want}"
  fi
  mv "${dest}.part" "${dest}"
  chmod a-w "${dest}"
  log "verified ${dest#"${CACHE_DIR}"/} (sha256 ${want})"
}

fetch_verified "${BASE_IMAGE}" "${IMAGE_SHA256}" "${IMAGE_URL_BASE}/${IMAGE_NAME}"

while read -r sum file url; do
  [[ -z "${sum}" || "${sum}" == \#* ]] && continue
  fetch_verified "${CACHE_DIR}/${file}" "${sum}" "${url}"
done < "${BASE_DIR}/deps.lock"
