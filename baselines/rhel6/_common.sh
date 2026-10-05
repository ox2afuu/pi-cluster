#!/usr/bin/env bash
# baselines/rhel6/_common.sh
# Shared settings for the CentOS 6.10 baseline VM scripts. Sourced, not run.
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${BASE_DIR}/../.." && pwd)"
CACHE_DIR="${BASE_DIR}/.cache"
STATE_DIR="${BASE_DIR}/.state"
RESULTS_DIR="${BASE_DIR}/results"

# Pinned image: the final CentOS 6 GenericCloud build (CentOS 6.10, 2019-07).
IMAGE_URL_BASE="https://cloud.centos.org/centos/6/images"
IMAGE_NAME="CentOS-6-x86_64-GenericCloud-1907.qcow2"
IMAGE_SHA256="5350c20875a3fec28157abbc7db5dc635911212804f892b751f94fcf3f285aec"
BASE_IMAGE="${CACHE_DIR}/${IMAGE_NAME}"

OVERLAY="${STATE_DIR}/overlay.qcow2"
OVERLAY_SIZE="${OVERLAY_SIZE:-40G}"
SEED_ISO="${STATE_DIR}/seed.iso"
SSH_KEY="${STATE_DIR}/id_ecdsa"
KNOWN_HOSTS="${STATE_DIR}/known_hosts"
PIDFILE="${STATE_DIR}/qemu.pid"
CONSOLE_LOG="${STATE_DIR}/console.log"
# AF_UNIX paths are capped at 104 bytes on macOS, so keep this one short.
MONITOR_SOCK="${TMPDIR:-/tmp}"
MONITOR_SOCK="${MONITOR_SOCK%/}/centos6-baseline-${SSH_PORT:-2226}.mon"

VM_USER="baseline"
VM_HOSTNAME="centos6-baseline"
# Loopback only: CentOS 6 is EOL and unpatched. Never change this to 0.0.0.0.
SSH_BIND="127.0.0.1"
SSH_PORT="${SSH_PORT:-2226}"

# Host-loopback caching proxy to vault.centos.org (vault-proxy.py). The
# guest reaches it as 10.0.2.2:${VAULT_PROXY_PORT}; the port is baked into
# guest/CentOS-Vault-6.10.repo, so change both together.
VAULT_PROXY_PORT=8610
VAULT_PROXY_PID="${STATE_DIR}/vault-proxy.pid"
VAULT_PROXY_LOG="${STATE_DIR}/vault-proxy.txt"

# QEMU tunables. ACCEL=kvm on an x86_64 Linux host; tcg everywhere else.
ACCEL="${ACCEL:-tcg}"
CPU_MODEL="${CPU_MODEL:-Nehalem}"
SMP="${SMP:-4}"
MEM="${MEM:-8G}"

# OpenSSH 5.3 only offers ssh-rsa/ssh-dss host keys (SHA-1 signatures), which
# OpenSSH >= 8.8 refuses by default. Re-enable ssh-rsa for this loopback-only
# VM and nothing else.
LEGACY_SSH_ALGS=(-o HostKeyAlgorithms=+ssh-rsa)
SSH_OPTS=(
  "${LEGACY_SSH_ALGS[@]}"
  -i "${SSH_KEY}"
  -p "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
  -o LogLevel=ERROR
)
SCP_OPTS=(
  "${LEGACY_SSH_ALGS[@]}"
  -i "${SSH_KEY}"
  -P "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# shellcheck disable=SC2029  # remote command strings are built deliberately
# shellcheck disable=SC2029  # remote command strings are built deliberately
vm_ssh() { ssh "${SSH_OPTS[@]}" "${VM_USER}@${SSH_BIND}" "$@"; }
vm_scp_to() { scp "${SCP_OPTS[@]}" "$1" "${VM_USER}@${SSH_BIND}:$2"; }
vm_scp_from() { scp "${SCP_OPTS[@]}" "${VM_USER}@${SSH_BIND}:$1" "$2"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# start_vault_proxy: run vault-proxy.py on 127.0.0.1 unless already running.
start_vault_proxy() {
  if [[ -f "${VAULT_PROXY_PID}" ]] && kill -0 "$(cat "${VAULT_PROXY_PID}")" 2>/dev/null; then
    return 0
  fi
  python3 "${BASE_DIR}/vault-proxy.py" --port "${VAULT_PROXY_PORT}" >>"${VAULT_PROXY_LOG}" 2>&1 &
  echo $! > "${VAULT_PROXY_PID}"
  sleep 1
  kill -0 "$(cat "${VAULT_PROXY_PID}")" 2>/dev/null || die "vault-proxy failed; see ${VAULT_PROXY_LOG}"
  log "vault-proxy on 127.0.0.1:${VAULT_PROXY_PORT} (pid $(cat "${VAULT_PROXY_PID}"))"
}

stop_vault_proxy() {
  if [[ -f "${VAULT_PROXY_PID}" ]]; then
    kill "$(cat "${VAULT_PROXY_PID}")" 2>/dev/null || true
    rm -f "${VAULT_PROXY_PID}"
  fi
}
