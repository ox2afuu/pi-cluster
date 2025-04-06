#!/usr/bin/env bash
#
# scripts/personalize-node.sh — write /boot/firmware/ivalice-node.conf onto
# a freshly-flashed SD/NVMe so the node picks up its role and identity on
# first boot. Runs on macOS only (diskutil).
#
# Cluster nodes are named after FFXII nations. Head is 'dalmasca'; workers
# are archadia, rozarria, bhujerba, nabradia, kerwon. Hostname ↔ IP mapping
# is enforced — see HOST_IPS below.
#
# Invocation modes:
#   personalize-node.sh                           # auto: pick next unpersonalized, prompt
#   personalize-node.sh <hostname>                # shortcut: infer role + IP
#   personalize-node.sh <hostname> <disk>         # shortcut + explicit disk
#   personalize-node.sh <role> <host> <ip> [disk] # legacy, still supported
#   personalize-node.sh --list                    # print personalization status
#
# Flags (work with any mode):
#   --with-k3s   opt this node into k3s (NODE_K3S=yes). Default: no.
#   --force      bypass validation / overwrite differing config
#   -h|--help    print usage
#
# Examples:
#   ./scripts/personalize-node.sh                          # personalizes the next pending node
#   ./scripts/personalize-node.sh archadia                 # infers worker + 10.42.0.11/24
#   ./scripts/personalize-node.sh kerwon --with-k3s
#   ./scripts/personalize-node.sh bhujerba /dev/disk6
#   ./scripts/personalize-node.sh --list
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAST_FILE="${REPO_ROOT}/.last-personalize"

# Canonical hostname → IP/CIDR mapping. Keep in sync with:
#   stages/.../files/etc/cloud/templates/hosts.debian.tmpl
#   stages/.../files/etc/slurm/slurm.conf
#   stages/.../files/opt/ivalice/ansible/inventory/hosts.yml
declare -A HOST_IPS=(
  [dalmasca]="10.42.0.1/24"
  [archadia]="10.42.0.11/24"
  [rozarria]="10.42.0.12/24"
  [bhujerba]="10.42.0.13/24"
  [nabradia]="10.42.0.14/24"
  [kerwon]="10.42.0.15/24"
)

# Canonical order used for auto-pick and --list (head first, then workers).
ORDERED_HOSTS=(dalmasca archadia rozarria bhujerba nabradia kerwon)
WORKER_NAMES=(archadia rozarria bhujerba nabradia kerwon)

role_for_host() {
  [[ "$1" == "dalmasca" ]] && echo head || echo worker
}

# Parse .last-personalize and populate DONE_HOSTS array with hostnames.
load_done_hosts() {
  DONE_HOSTS=()
  [[ -f "${LAST_FILE}" ]] || return 0
  while IFS='|' read -r _r h _ip _disk _ts; do
    [[ -n "${h:-}" ]] && DONE_HOSTS+=("${h}")
  done < "${LAST_FILE}"
}

is_done() {
  local needle="$1"
  local d
  for d in "${DONE_HOSTS[@]}"; do
    [[ "${needle}" == "${d}" ]] && return 0
  done
  return 1
}

usage() {
  cat >&2 <<EOF
Usage:
  personalize-node.sh                                    # auto: next pending node, prompt
  personalize-node.sh <hostname>                         # infer role + IP
  personalize-node.sh <hostname> <disk>                  # + explicit disk identifier
  personalize-node.sh <role> <host> <ip/cidr> [disk]     # legacy (explicit)
  personalize-node.sh --list                             # print personalization status

Flags:
  --with-k3s   opt this node into k3s (NODE_K3S=yes). Default: no.
  --force      bypass validation / overwrite differing config
  -h|--help    print usage

Known hostnames: ${ORDERED_HOSTS[*]}
EOF
}

# --- Parse args ---------------------------------------------------------------
FORCE=0
WITH_K3S=no
LIST=0
POSITIONAL=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help)   usage; exit 0 ;;
    --force)     FORCE=1 ;;
    --with-k3s)  WITH_K3S=yes ;;
    --list)      LIST=1 ;;
    *)           POSITIONAL+=("${arg}") ;;
  esac
done

# --- --list mode: print status and exit ---------------------------------------
if [[ ${LIST} -eq 1 ]]; then
  load_done_hosts
  if [[ -f "${LAST_FILE}" ]]; then
    printf "Personalization status (source: %s)\n\n" "${LAST_FILE}"
  else
    printf "Personalization status (no %s yet — nothing personalized)\n\n" "${LAST_FILE}"
  fi
  printf "  %-10s  %-8s  %-10s  %s\n" "Status" "Role" "Hostname" "IP"
  printf "  %-10s  %-8s  %-10s  %s\n" "---------" "----" "--------" "--"
  for name in "${ORDERED_HOSTS[@]}"; do
    role="$(role_for_host "${name}")"
    ip="${HOST_IPS[${name}]}"
    if is_done "${name}"; then
      status="[done]   "
    else
      status="[pending]"
    fi
    printf "  %-10s  %-8s  %-10s  %s\n" "${status}" "${role}" "${name}" "${ip}"
  done
  exit 0
fi

# --- Dispatch by positional-arg count ----------------------------------------
# 0 pos           → auto (pick next unpersonalized, prompt)
# 1 or 2 pos      → shortcut (hostname, optional disk)
# 3 or 4 pos      → legacy (role, host, ip, optional disk)
ROLE=""
HOST=""
IP=""
DISK=""

case ${#POSITIONAL[@]} in
  0)
    MODE=auto
    ;;
  1)
    MODE=shortcut
    HOST="${POSITIONAL[0]}"
    ;;
  2)
    MODE=shortcut
    HOST="${POSITIONAL[0]}"
    DISK="${POSITIONAL[1]}"
    ;;
  3|4)
    if [[ "${POSITIONAL[0]}" != "head" && "${POSITIONAL[0]}" != "worker" ]]; then
      echo "ERROR: with 3+ positional args, first must be 'head' or 'worker' (got '${POSITIONAL[0]}')" >&2
      usage
      exit 2
    fi
    MODE=legacy
    ROLE="${POSITIONAL[0]}"
    HOST="${POSITIONAL[1]}"
    IP="${POSITIONAL[2]}"
    DISK="${POSITIONAL[3]:-}"
    ;;
  *)
    usage
    exit 2
    ;;
esac

# --- Auto mode: pick next pending, confirm ------------------------------------
if [[ "${MODE}" == "auto" ]]; then
  load_done_hosts
  next=""
  for c in "${ORDERED_HOSTS[@]}"; do
    if ! is_done "${c}"; then
      next="${c}"
      break
    fi
  done
  if [[ -z "${next}" ]]; then
    echo "All 6 nodes already personalized. Use --list to review, or pass a hostname explicitly to re-personalize." >&2
    exit 0
  fi
  HOST="${next}"
  ROLE="$(role_for_host "${HOST}")"
  IP="${HOST_IPS[${HOST}]}"

  if [[ ! -t 0 ]]; then
    echo "ERROR: auto mode needs an interactive terminal (stdin is not a TTY)." >&2
    echo "       Pass the hostname explicitly: ./scripts/personalize-node.sh ${HOST}" >&2
    exit 1
  fi

  k3s_note=""
  [[ "${WITH_K3S}" == "yes" ]] && k3s_note=" [NODE_K3S=yes]"
  echo "Next pending: ${HOST} (${ROLE}, ${IP})${k3s_note}"
  read -r -p "Proceed? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# --- Shortcut mode: resolve hostname → role + IP ------------------------------
if [[ "${MODE}" == "shortcut" ]]; then
  if [[ -z "${HOST_IPS[${HOST}]:-}" ]]; then
    echo "ERROR: unknown hostname '${HOST}'. Known: ${ORDERED_HOSTS[*]}" >&2
    echo "       (For a non-canonical name, use the 3-arg legacy form with --force.)" >&2
    exit 1
  fi
  ROLE="$(role_for_host "${HOST}")"
  IP="${HOST_IPS[${HOST}]}"
fi

# --- Validate (legacy mode revalidates; auto/shortcut are already consistent) -
validation_error() {
  local msg="$1"
  if [[ ${FORCE} -eq 1 ]]; then
    echo "WARNING: ${msg} (proceeding because --force)" >&2
  else
    echo "ERROR: ${msg}" >&2
    exit 1
  fi
}

if [[ "${ROLE}" != "head" && "${ROLE}" != "worker" ]]; then
  echo "ERROR: role must be 'head' or 'worker' (got '${ROLE}')" >&2
  usage
  exit 2
fi

if [[ "${MODE}" == "legacy" ]]; then
  if [[ "${ROLE}" == "head" ]]; then
    if [[ "${HOST}" != "dalmasca" ]]; then
      validation_error "head hostname must be 'dalmasca' (got '${HOST}')"
    fi
  else
    known=0
    for n in "${WORKER_NAMES[@]}"; do
      [[ "${HOST}" == "${n}" ]] && { known=1; break; }
    done
    [[ ${known} -eq 0 ]] && validation_error "worker hostname must be one of: ${WORKER_NAMES[*]} (got '${HOST}')"
  fi
  expected_ip="${HOST_IPS[${HOST}]:-}"
  if [[ -n "${expected_ip}" && "${IP}" != "${expected_ip}" ]]; then
    validation_error "${HOST} IP must be '${expected_ip}' (got '${IP}')"
  fi
fi

# --- Platform check -----------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this script only supports macOS (diskutil)." >&2
  exit 1
fi

# --- Find bootfs mount --------------------------------------------------------
if [[ -z "${DISK}" ]]; then
  MOUNT_POINT="$(diskutil info bootfs 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')" || true
  if [[ -z "${MOUNT_POINT}" ]]; then
    echo "ERROR: couldn't find a mounted 'bootfs' volume. Insert the card or pass DISK explicitly." >&2
    exit 1
  fi
else
  diskutil mount "${DISK}s1" >/dev/null || true
  MOUNT_POINT="$(diskutil info "${DISK}s1" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2; exit}')" || true
  if [[ -z "${MOUNT_POINT}" ]]; then
    echo "ERROR: couldn't mount ${DISK}s1." >&2
    exit 1
  fi
fi

TARGET="${MOUNT_POINT}/ivalice-node.conf"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NEW_CONTENT="$(cat <<EOF
# Written by scripts/personalize-node.sh on ${TIMESTAMP}
NODE_ROLE=${ROLE}
NODE_HOSTNAME=${HOST}
NODE_IP=${IP}
NODE_K3S=${WITH_K3S}
EOF
)"

# --- Idempotent compare, ignoring the timestamp comment ----------------------
strip_ts() {
  grep -E '^NODE_(ROLE|HOSTNAME|IP|K3S)=' || true
}

if [[ -f "${TARGET}" ]]; then
  existing_body="$(strip_ts < "${TARGET}")"
  new_body="$(printf '%s\n' "${NEW_CONTENT}" | strip_ts)"
  if [[ "${existing_body}" == "${new_body}" ]]; then
    echo "[ok] unchanged"
    if diskutil eject "${MOUNT_POINT}" >/dev/null 2>&1; then
      echo "Ejected ${MOUNT_POINT}. Safe to remove the card."
    fi
    exit 0
  fi
  if [[ ${FORCE} -ne 1 ]]; then
    echo "ERROR: refusing to overwrite differing config; pass --force to override" >&2
    exit 1
  fi
fi

# --- Head duplicate warning (best-effort) -------------------------------------
if [[ "${ROLE}" == "head" && -f "${LAST_FILE}" ]]; then
  last_head_line="$(grep '^head|' "${LAST_FILE}" | tail -n1 || true)"
  if [[ -n "${last_head_line}" ]]; then
    IFS='|' read -r _lrole _lhost _lip _ldisk _lts <<<"${last_head_line}"
    if [[ "${_ldisk}" != "${DISK:-bootfs}" ]]; then
      now_epoch="$(date -u +%s)"
      last_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${_lts}" +%s 2>/dev/null || echo 0)"
      if [[ ${last_epoch} -gt 0 ]]; then
        delta=$(( now_epoch - last_epoch ))
        if [[ ${delta} -lt 86400 ]]; then
          echo "WARNING: a 'head' node was already personalized on disk '${_ldisk}' at ${_lts} (${delta}s ago). Two heads fighting for 10.42.0.1 is not a thing you want." >&2
        fi
      fi
    fi
  fi
fi

# --- Write --------------------------------------------------------------------
printf '%s\n' "${NEW_CONTENT}" > "${TARGET}"

echo "Wrote ${TARGET}:"
cat "${TARGET}"

echo "${ROLE}|${HOST}|${IP}|${DISK:-bootfs}|${TIMESTAMP}" >> "${LAST_FILE}"

# --- Eject --------------------------------------------------------------------
if diskutil eject "${MOUNT_POINT}" >/dev/null 2>&1; then
  echo "Ejected ${MOUNT_POINT}. Safe to remove the card."
else
  echo "NOTE: couldn't auto-eject; please eject ${MOUNT_POINT} manually."
fi
