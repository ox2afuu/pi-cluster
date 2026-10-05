#!/usr/bin/env bash
# baselines/rhel6/run-checks.sh
# Verify the provisioned CentOS 6.10 baseline VM and collect artifacts:
#   1. the sphinx-asr pytest suite under the guest's Python 3.12;
#   2. tool sanity: sphinx_fe and bw (gcc 4.4.7 builds) print their usage;
#   3. regenerate ~/TOOLCHAIN-MANIFEST.txt and copy it, with the check
#      transcript, to results/ (committed research artifacts).
#
# Usage: ./run-checks.sh            (VM up and provisioned)
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

vm_ssh -o BatchMode=yes true 2>/dev/null || die "VM not reachable; run ./vm.sh up first"
mkdir -p "${RESULTS_DIR}"
vm_scp_to "${BASE_DIR}/guest/provision-guest.sh" "stage/" >/dev/null

# Runs in the guest's bash 4.1. Single-quoted on purpose: expands remotely.
# shellcheck disable=SC2016
vm_ssh 'bash -s' > "${RESULTS_DIR}/run-checks.txt" 2>&1 <<'GUEST' || true
set -u
cd ~/sphinx-asr
ARCH=$(uname -m)
status=0
echo "# run-checks: $(date -u '+%Y-%m-%dT%H:%M:%SZ') on $(uname -n), sphinx-asr $(cat .git-sha)"
echo
echo "## pytest (sphinx-asr suite, $(.venv/bin/python3 -V))"
start=$(date +%s)
.venv/bin/python3 -m pytest -q -p no:cacheprovider 2>&1 | tail -15
rc=${PIPESTATUS[0]}
echo "pytest exit=${rc} wall=$(( $(date +%s) - start ))s (TCG, not a timing result)"
[ "${rc}" -eq 0 ] || status=1
echo
echo "## tool sanity (bin/${ARCH}, built with $(/usr/bin/gcc --version | head -1))"
for tool in sphinx_fe bw; do
  out=$("bin/${ARCH}/${tool}" 2>&1 | head -40)
  if echo "${out}" | grep -q -E '^\[NAME\]|Arguments list definition|-help'; then
    echo "${tool}: OK (prints usage)"
    echo "${out}" | head -8 | sed 's/^/    /'
  else
    echo "${tool}: FAIL"
    echo "${out}" | head -8 | sed 's/^/    /'
    status=1
  fi
done
for tool in pocketsphinx_batch text2wfreq idngram2lm; do
  if [ -x "bin/${ARCH}/${tool}" ]; then echo "${tool}: present"; else echo "${tool}: MISSING"; status=1; fi
done
echo
echo "## binaries whose .comment names a compiler other than GCC 4.4.7"
other=$(for f in bin/${ARCH}/*; do
  file "$f" | grep -q ELF || continue
  readelf -p .comment "$f" 2>/dev/null | grep -o 'GCC: ([^)]*) [0-9.]*' | grep -v ' 4\.4\.7' | sed "s|^|$(basename "$f"): |"
done | sort -u)
if [ -z "${other}" ]; then echo "none (all ELF objects report GCC 4.4.7)"; else echo "${other}"; status=1; fi
echo
echo "RESULT: $([ "${status}" -eq 0 ] && echo PASS || echo FAIL)"
GUEST

vm_ssh 'bash ~/stage/provision-guest.sh manifest' >/dev/null
vm_scp_from "TOOLCHAIN-MANIFEST.txt" "${RESULTS_DIR}/TOOLCHAIN-MANIFEST.txt"
cat "${RESULTS_DIR}/run-checks.txt"
log "artifacts: ${RESULTS_DIR}/run-checks.txt, ${RESULTS_DIR}/TOOLCHAIN-MANIFEST.txt"
grep -q '^RESULT: PASS' "${RESULTS_DIR}/run-checks.txt"
