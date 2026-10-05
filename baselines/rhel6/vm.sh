#!/usr/bin/env bash
# baselines/rhel6/vm.sh
# Lifecycle of the CentOS 6.10 x86_64 baseline VM under plain QEMU.
#
# Usage: ./vm.sh {up|down|ssh [CMD...]|status|destroy --yes}
#
# Environment (all optional):
#   ACCEL=tcg       QEMU accelerator. tcg = full emulation (Apple Silicon and
#                   any non-x86 host; timings NOT valid). kvm = x86_64 Linux
#                   host with /dev/kvm (timings valid).
#   CPU_MODEL=Nehalem  guest CPU model (e.g. "host" with ACCEL=kvm)
#   SMP=4  MEM=8G  OVERLAY_SIZE=40G  SSH_PORT=2226  MACHINE=q35
#   BOOT_WAIT=1800  seconds to wait for sshd after boot
#
# Security: CentOS 6 is EOL (no security updates since 2020-11-30). The VM's
# only listener is the ssh forward on 127.0.0.1 (provision.sh adds a host
# vault-proxy.py on 127.0.0.1 while it runs); nothing binds a routable address.
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

MACHINE="${MACHINE:-q35}"
BOOT_WAIT="${BOOT_WAIT:-1800}"

is_running() {
  [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null
}

accel_opts() {
  case "${ACCEL}" in
    tcg) echo "tcg,thread=multi,tb-size=1024" ;;
    *) echo "${ACCEL}" ;;
  esac
}

wait_for_ssh() {
  local deadline=$((SECONDS + BOOT_WAIT))
  log "waiting up to ${BOOT_WAIT}s for sshd on ${SSH_BIND}:${SSH_PORT} (TCG boots slowly)"
  until vm_ssh -o BatchMode=yes true 2>/dev/null; do
    is_running || die "qemu exited; see ${CONSOLE_LOG}"
    ((SECONDS < deadline)) || die "sshd not reachable after ${BOOT_WAIT}s; see ${CONSOLE_LOG}"
    sleep 10
  done
  log "sshd is up"
}

cmd_up() {
  if is_running; then
    log "already running (pid $(cat "${PIDFILE}"))"
    wait_for_ssh
    return
  fi
  [[ -f "${BASE_IMAGE}" ]] || "${BASE_DIR}/fetch-image.sh"
  [[ -f "${SEED_ISO}" && -f "${SSH_KEY}" ]] || "${BASE_DIR}/make-seed.sh"
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${OVERLAY}" ]]; then
    log "creating ${OVERLAY_SIZE} overlay on ${IMAGE_NAME}"
    qemu-img create -q -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${OVERLAY}" "${OVERLAY_SIZE}"
  fi
  rm -f "${MONITOR_SOCK}"
  log "booting: machine=${MACHINE} accel=$(accel_opts) cpu=${CPU_MODEL} smp=${SMP} mem=${MEM}"
  # Legacy virtio (disable-legacy=off): the 2.6.32 kernel predates virtio 1.0.
  qemu-system-x86_64 \
    -name centos6-baseline \
    -machine "${MACHINE}" \
    -accel "$(accel_opts)" \
    -cpu "${CPU_MODEL}" \
    -smp "${SMP}" \
    -m "${MEM}" \
    -drive "file=${OVERLAY},if=none,id=hd0,format=qcow2,cache=writeback,discard=unmap" \
    -device virtio-blk-pci,drive=hd0,disable-legacy=off,bootindex=0 \
    -drive "file=${SEED_ISO},if=none,id=seed,format=raw,readonly=on" \
    -device virtio-blk-pci,drive=seed,disable-legacy=off \
    -netdev "user,id=n0,hostname=${VM_HOSTNAME},hostfwd=tcp:${SSH_BIND}:${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=n0,disable-legacy=off \
    -display none \
    -serial "file:${CONSOLE_LOG}" \
    -monitor "unix:${MONITOR_SOCK},server=on,wait=off" \
    -pidfile "${PIDFILE}" \
    -daemonize
  log "qemu pid $(cat "${PIDFILE}"); console log ${CONSOLE_LOG}"
  wait_for_ssh
}

cmd_down() {
  if ! is_running; then
    log "not running"
    rm -f "${PIDFILE}"
    return
  fi
  local pid
  pid="$(cat "${PIDFILE}")"
  log "requesting guest poweroff"
  vm_ssh -o BatchMode=yes 'sudo /sbin/poweroff' 2>/dev/null || true
  local i
  for ((i = 0; i < 60; i++)); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 5
  done
  if kill -0 "${pid}" 2>/dev/null && [[ -S "${MONITOR_SOCK}" ]]; then
    log "guest still up; sending ACPI system_powerdown"
    echo system_powerdown | nc -U "${MONITOR_SOCK}" >/dev/null 2>&1 || true
    for ((i = 0; i < 24; i++)); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 5
    done
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    log "forcing qemu to quit"
    kill "${pid}" || true
  fi
  rm -f "${PIDFILE}" "${MONITOR_SOCK}"
  log "stopped (overlay kept: ${OVERLAY})"
}

cmd_status() {
  if is_running; then
    echo "running: pid $(cat "${PIDFILE}"), ssh ${SSH_BIND}:${SSH_PORT}, accel ${ACCEL}"
    if vm_ssh -o BatchMode=yes 'uname -r; cat /etc/redhat-release' 2>/dev/null; then
      echo "ssh: ok"
    else
      echo "ssh: not reachable yet"
    fi
  else
    echo "stopped"
  fi
  [[ -f "${OVERLAY}" ]] && qemu-img info -U --output=human "${OVERLAY}" | grep -E '^(image|virtual size|disk size|backing file):'
  return 0
}

cmd_destroy() {
  [[ "${1:-}" == "--yes" ]] || die "destroy deletes the overlay disk; re-run as: $0 destroy --yes"
  cmd_down
  rm -f "${OVERLAY}" "${KNOWN_HOSTS}" "${CONSOLE_LOG}" "${SEED_ISO}"
  log "removed overlay, seed, console log and known_hosts (key and cached image kept)"
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  ssh) shift; exec ssh "${SSH_OPTS[@]}" "${VM_USER}@${SSH_BIND}" "$@" ;;
  status) cmd_status ;;
  destroy) shift; cmd_destroy "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
esac
