#!/usr/bin/env bash
# baselines/rhel6/make-seed.sh
# Build the cloud-init NoCloud seed ISO (volume id "cidata") for the CentOS
# 6.10 baseline VM. Generates a dedicated VM-only ssh key into .state/ on
# first run; the operator's own keys are never read or copied.
#
# Key type: ECDSA P-256, not ed25519. CentOS 6 ships OpenSSH 5.3p1 (RHEL
# backports ECDSA/ECDH, not ed25519, which arrived upstream in 6.5).
#
# cloud-init on CentOS 6 is 0.7.5: only long-standing keys are used here
# (users, ssh_pwauth, disable_root, write_files, bootcmd, runcmd).
#
# Usage: ./make-seed.sh        (re-run after editing; vm.sh up calls it)
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

command -v xorriso >/dev/null || die "xorriso not found (brew install xorriso)"
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

if [[ ! -f "${SSH_KEY}" ]]; then
  log "generating dedicated VM key ${SSH_KEY}"
  ssh-keygen -q -t ecdsa -b 256 -N '' -C "${VM_USER}@${VM_HOSTNAME}" -f "${SSH_KEY}"
fi
pubkey="$(cat "${SSH_KEY}.pub")"

seed_dir="$(mktemp -d "${STATE_DIR}/seed.XXXXXX")"
trap 'rm -rf "${seed_dir}"' EXIT

cat > "${seed_dir}/meta-data" <<META
instance-id: ${VM_HOSTNAME}-1
local-hostname: ${VM_HOSTNAME}
META

# The vault repo file replaces CentOS-Base.repo, whose mirrorlist is dead.
# Same file that provision.sh pushes later (guest/CentOS-Vault-6.10.repo).
repo_content="$(sed 's/^/      /' "${BASE_DIR}/guest/CentOS-Vault-6.10.repo")"
cat > "${seed_dir}/user-data" <<USERDATA
#cloud-config
users:
  - name: ${VM_USER}
    gecos: CentOS 6 legacy baseline
    groups: wheel
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
    ssh_authorized_keys:
      - ${pubkey}
disable_root: true
ssh_pwauth: false
preserve_hostname: false
hostname: ${VM_HOSTNAME}
write_files:
  - path: /etc/yum.repos.d/CentOS-Vault-6.10.repo
    permissions: '0644'
    owner: root:root
    content: |
${repo_content}
bootcmd:
  - [sh, -c, 'for f in /etc/yum.repos.d/CentOS-*.repo; do case "\$f" in *Vault-6.10*) ;; *) mv -f "\$f" "\$f.disabled" ;; esac; done']
runcmd:
  - [passwd, -l, root]
  - [sed, -i, 's/^enabled=1/enabled=0/', /etc/yum/pluginconf.d/fastestmirror.conf]
  - [sh, -c, 'echo "cloud-init seed applied \$(date -u +%FT%TZ)" > /var/tmp/seed-applied']
USERDATA

rm -f "${SEED_ISO}"
xorriso -as mkisofs -quiet -output "${SEED_ISO}" -volid cidata -joliet -rock \
  "${seed_dir}/user-data" "${seed_dir}/meta-data"
log "wrote ${SEED_ISO}"
