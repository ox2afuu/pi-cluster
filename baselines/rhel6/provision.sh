#!/usr/bin/env bash
# baselines/rhel6/provision.sh
# Provision the running CentOS 6.10 baseline VM over ssh:
#   1. stage pinned inputs into ~/stage (cmake, Python source, wheelhouse,
#      a `git archive` of the sphinx-asr submodule at its pinned HEAD);
#   2. yum-install the legacy toolchain from the 6.10 vault;
#   3. grow the root partition to the 40G overlay (one reboot);
#   4. build Python 3.12 into /opt/py312 (devtoolset-8, orchestration only);
#   5. create sphinx-asr/.venv offline (pytest, pyyaml);
#   6. apply patches/*.patch (gcc 4.4 declaration fixes) to the guest copy,
#      then `make clean && make` sphinx-asr with the system gcc 4.4.7;
#   7. write ~/TOOLCHAIN-MANIFEST.txt.
# Phases are resumable: a rerun skips what already finished.
#
# Usage: ./provision.sh            (VM must be up: ./vm.sh up)
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

SUBMODULE="${REPO_ROOT}/sphinx-asr"

vm_ssh -o BatchMode=yes true 2>/dev/null || die "VM not reachable; run ./vm.sh up first"
"${BASE_DIR}/fetch-image.sh" >/dev/null

log "staging inputs"
sha="$(git -C "${SUBMODULE}" rev-parse HEAD)"
pinned="$(git -C "${REPO_ROOT}" ls-tree HEAD sphinx-asr | awk '{print $3}')"
[[ "${sha}" == "${pinned}" ]] || log "WARNING: sphinx-asr HEAD ${sha} differs from superproject pin ${pinned}"
if [[ -n "$(git -C "${SUBMODULE}" status --porcelain --untracked-files=no)" ]]; then
  log "WARNING: sphinx-asr has uncommitted changes; git archive uses HEAD only"
fi
git -C "${SUBMODULE}" archive --format=tar -o "${STATE_DIR}/sphinx-asr.tar" HEAD
echo "${sha}" > "${STATE_DIR}/sphinx-asr.sha"
# --no-xattrs/COPYFILE_DISABLE: no macOS metadata headers for the guest tar.
COPYFILE_DISABLE=1 tar --no-xattrs --format=ustar -cf "${STATE_DIR}/wheelhouse.tar" -C "${CACHE_DIR}" wheelhouse

start_vault_proxy
trap stop_vault_proxy EXIT

vm_ssh 'mkdir -p ~/stage'
for f in "${CACHE_DIR}/cmake-3.25.3-linux-x86_64.tar.gz" "${CACHE_DIR}/Python-3.12.15.tar.xz" \
         "${STATE_DIR}/wheelhouse.tar" "${STATE_DIR}/sphinx-asr.tar" "${STATE_DIR}/sphinx-asr.sha" \
         "${BASE_DIR}/guest/provision-guest.sh" "${BASE_DIR}/guest/CentOS-Vault-6.10.repo"; do
  vm_scp_to "${f}" "stage/"
done
vm_ssh 'rm -rf ~/stage/patches && mkdir -p ~/stage/patches'
for f in "${BASE_DIR}"/patches/*.patch; do
  vm_scp_to "${f}" "stage/patches/"
done
vm_ssh 'cd ~/stage && rm -rf wheelhouse && tar -xf wheelhouse.tar && chmod +x provision-guest.sh \
  && sudo install -m 0644 CentOS-Vault-6.10.repo /etc/yum.repos.d/CentOS-Vault-6.10.repo \
  && sudo yum -q clean all'

guest() { vm_ssh "bash ~/stage/provision-guest.sh $*"; }

guest packages

grow_out="$(guest grow-check)"
echo "${grow_out}"
if [[ "${grow_out}" == *NEEDS_REBOOT* ]]; then
  log "rebooting so the kernel sees the grown partition"
  vm_ssh 'sudo /sbin/reboot' || true
  sleep 20
  deadline=$((SECONDS + 1800))
  until vm_ssh -o BatchMode=yes true 2>/dev/null; do
    ((SECONDS < deadline)) || die "VM did not come back after reboot"
    sleep 10
  done
fi
guest resize

guest python venv sphinx manifest
log "provisioning complete; manifest at ~${VM_USER}/TOOLCHAIN-MANIFEST.txt in the guest"
