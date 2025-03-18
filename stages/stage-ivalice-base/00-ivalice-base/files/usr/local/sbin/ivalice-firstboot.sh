#!/usr/bin/env bash
# /usr/local/sbin/ivalice-firstboot.sh
# Reads /boot/firmware/ivalice-node.conf, applies hostname, static IP, and
# enables the correct k3s systemd unit for the selected role. Idempotent:
# refuses to run a second time once /var/lib/ivalice/firstboot.done exists.
# cloud-init's manage_etc_hosts: template owns /etc/hosts — do not touch it.
set -euo pipefail

CONF=/boot/firmware/ivalice-node.conf
MARKER=/var/lib/ivalice/firstboot.done
NET_FILE=/etc/systemd/network/10-eth0.network
NET_TEMPLATE=${NET_FILE}.template
K3S_DIR=/etc/rancher/k3s
K3S_ACTIVE=${K3S_DIR}/config.yaml

log() { echo "[ivalice-firstboot] $*" >&2; }

if [[ -f "${MARKER}" ]]; then
    log "already personalized ($(cat "${MARKER}" 2>/dev/null || true)); exiting"
    exit 0
fi

if [[ ! -f "${CONF}" ]]; then
    log "ERROR: ${CONF} missing; refusing to run"
    exit 1
fi

# shellcheck disable=SC1090
. "${CONF}"
: "${NODE_ROLE:?NODE_ROLE missing in ${CONF}}"
: "${NODE_HOSTNAME:?NODE_HOSTNAME missing in ${CONF}}"
: "${NODE_IP:?NODE_IP missing in ${CONF}}"

case "${NODE_ROLE}" in
    head|worker) ;;
    *) log "ERROR: NODE_ROLE must be 'head' or 'worker' (got '${NODE_ROLE}')"; exit 1 ;;
esac

mkdir -p /var/lib/ivalice /var/log/ivalice
install -d -m 0755 "${K3S_DIR}"

# --- hostname (file + hostnamectl; cloud-init preserves it via preserve_hostname) ---
echo "${NODE_HOSTNAME}" > /etc/hostname
hostnamectl set-hostname "${NODE_HOSTNAME}" || true

# --- static network (copy template if needed, then substitute placeholder) ---
if [[ ! -f "${NET_FILE}" ]]; then
    if [[ ! -f "${NET_TEMPLATE}" ]]; then
        log "ERROR: neither ${NET_FILE} nor ${NET_TEMPLATE} present"
        exit 1
    fi
    cp "${NET_TEMPLATE}" "${NET_FILE}"
fi
sed -i "s|__STATIC_ADDRESS__|${NODE_IP}|g" "${NET_FILE}"

# --- common on every node -------------------------------------------------
systemctl enable munge.service

# --- role dispatch --------------------------------------------------------
if [[ "${NODE_ROLE}" == "head" ]]; then
    systemctl enable  slurmctld.service
    systemctl disable slurmd.service 2>/dev/null || true
    ln -sf "${K3S_DIR}/config.head.yaml" "${K3S_ACTIVE}"
    systemctl enable  ivalice-postboot-ansible.service
    touch /var/lib/ivalice/role.head
else
    systemctl enable  slurmd.service
    systemctl disable slurmctld.service 2>/dev/null || true
    # Copy-then-sed to keep the baked config.worker.yaml pristine for reference.
    install -m 0600 "${K3S_DIR}/config.worker.yaml" "${K3S_ACTIVE}"
    sed -i "s|^node-name:.*|node-name: ${NODE_HOSTNAME}|" "${K3S_ACTIVE}"
    # Workers have no business SSHing anywhere else; remove the cluster private key.
    rm -f /root/.ssh/ivalice-cluster
    touch /var/lib/ivalice/role.worker
fi

# --- k3s opt-in per node --------------------------------------------------
case "${NODE_K3S:-no}" in
    yes|true|1)
        if [[ "${NODE_ROLE}" == "head" ]]; then
            systemctl enable  k3s.service
            systemctl disable k3s-agent.service 2>/dev/null || true
        else
            systemctl enable  k3s-agent.service
            systemctl disable k3s.service 2>/dev/null || true
        fi
        touch /var/lib/ivalice/k3s.enabled
        ;;
    *)
        systemctl disable k3s.service       2>/dev/null || true
        systemctl disable k3s-agent.service 2>/dev/null || true
        ;;
esac

date --iso-8601=seconds > "${MARKER}"
log "role=${NODE_ROLE} host=${NODE_HOSTNAME} ip=${NODE_IP} done"
