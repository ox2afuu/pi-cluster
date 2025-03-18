#!/usr/bin/env bash
# /usr/local/sbin/ivalice-wait-for-workers.sh
# ExecStartPre for ivalice-postboot-ansible.service. Polls the five worker IPs
# once per pass; exits 0 once >=3 respond to an ICMP echo in the same pass.
# Gives up after 600 seconds.
set -u

WORKERS=(10.42.0.11 10.42.0.12 10.42.0.13 10.42.0.14 10.42.0.15)
QUORUM=3
DEADLINE=$(( $(date +%s) + 600 ))
PASS=0

log() { echo "[ivalice-wait] $*" >&2; }

while [[ $(date +%s) -lt ${DEADLINE} ]]; do
    PASS=$((PASS + 1))
    alive=0
    responders=()
    for ip in "${WORKERS[@]}"; do
        if ping -c 1 -W 2 "${ip}" >/dev/null 2>&1; then
            alive=$((alive + 1))
            responders+=("${ip}")
        fi
    done
    log "pass ${PASS}: ${alive}/${#WORKERS[@]} up (${responders[*]:-none})"
    if [[ ${alive} -ge ${QUORUM} ]]; then
        log "quorum reached (${alive} >= ${QUORUM}); proceeding"
        exit 0
    fi
    sleep 10
done

log "timed out after 600s without quorum; giving up"
exit 1
