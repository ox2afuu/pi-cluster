#!/bin/bash -e
# stage-ivalice-base/00-ivalice-base/01-run.sh
#
# Runs after 00-packages has installed the unified package set. Copies the
# 'files/' tree into the rootfs, configures userconf.txt / subuid-subgid /
# cgroups / systemd services, and installs BOTH k3s roles (server and agent)
# in disabled state. First-boot dispatch picks the active role per
# /boot/firmware/ivalice-node.conf.
#
# Per pi-gen conventions, `on_chroot` runs a block of commands inside the
# target rootfs; `install -m` / cp happen outside the chroot against
# ${ROOTFS_DIR}.

# --- drop the files/ tree into the rootfs ---------------------------------
# pi-gen's rsync_exclude file doesn't apply here — we use a simple cp.
cp -a files/. "${ROOTFS_DIR}/"

chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/ivalice-firstboot.sh"
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/ivalice-wait-for-workers.sh"
chmod 0644 "${ROOTFS_DIR}/etc/systemd/system/ivalice-firstboot.service"
chmod 0644 "${ROOTFS_DIR}/etc/systemd/system/ivalice-postboot-ansible.service"

# Ownership for the ivalice user's home content.
chown -R 1000:1000 "${ROOTFS_DIR}/home/ivalice" || true
chmod 0755 "${ROOTFS_DIR}/home/ivalice/.bashrc.d"
chmod 0644 "${ROOTFS_DIR}/home/ivalice/.bashrc.d/ivalice.sh"

# --- write userconf.txt for Raspberry Pi OS first-boot user provisioning --
# pi-gen also creates the user via chpasswd internally, but shipping a
# userconf.txt with a SHA-512 crypt is a belt-and-braces fallback that
# survives any future changes to pi-gen's user handling.
mkdir -p "${ROOTFS_DIR}/boot/firmware"
_pass_hash="$(openssl passwd -6 "${FIRST_USER_PASS}")"
echo "${FIRST_USER_NAME}:${_pass_hash}" > "${ROOTFS_DIR}/boot/firmware/userconf.txt"
chmod 0600 "${ROOTFS_DIR}/boot/firmware/userconf.txt"

# --- locate and validate airgap assets ------------------------------------
# ${STAGE_DIR} points at stages/stage-ivalice-base. Assets sit at
# ../../assets at repo root, accessible via pi-gen's bind-mount.
ASSETS="${STAGE_DIR}/../../assets"

for f in k3s k3s-install.sh k3s-airgap-images-arm64.tar.zst cluster-token ivalice-cluster ivalice-cluster.pub munge.key ohmyzsh.tar.gz; do
  if [[ ! -s "${ASSETS}/${f}" ]]; then
    echo "ERROR: missing asset ${ASSETS}/${f}; run scripts/download-assets.sh, scripts/generate-token.sh, and scripts/generate-ssh-key.sh first" >&2
    exit 1
  fi
done

# --- lay down k3s binary, installer, airgap tar, token, SSH key -----------
install -d -m 0755 "${ROOTFS_DIR}/usr/local/bin" \
                    "${ROOTFS_DIR}/usr/local/sbin" \
                    "${ROOTFS_DIR}/var/lib/rancher/k3s/server" \
                    "${ROOTFS_DIR}/var/lib/rancher/k3s/agent/images" \
                    "${ROOTFS_DIR}/etc/rancher/k3s" \
                    "${ROOTFS_DIR}/root/.ssh"

install -m 0755 "${ASSETS}/k3s"            "${ROOTFS_DIR}/usr/local/bin/k3s"
install -m 0755 "${ASSETS}/k3s-install.sh" "${ROOTFS_DIR}/usr/local/sbin/k3s-install.sh"
install -m 0644 "${ASSETS}/k3s-airgap-images-arm64.tar.zst" \
  "${ROOTFS_DIR}/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar.zst"
install -m 0600 "${ASSETS}/cluster-token" "${ROOTFS_DIR}/var/lib/rancher/k3s/server/token"
install -m 0600 "${ASSETS}/ivalice-cluster"     "${ROOTFS_DIR}/root/.ssh/ivalice-cluster"
install -m 0644 "${ASSETS}/ivalice-cluster.pub" "${ROOTFS_DIR}/root/.ssh/ivalice-cluster.pub"

install -d -m 0700 "${ROOTFS_DIR}/etc/munge"
install -m 0400 "${ASSETS}/munge.key" "${ROOTFS_DIR}/etc/munge/munge.key"
# ownership fixed inside chroot (munge user exists after apt)

# --- generate worker config with baked token ------------------------------
TOKEN="$(cat "${ASSETS}/cluster-token")"
cat > "${ROOTFS_DIR}/etc/rancher/k3s/config.worker.yaml" <<EOF
server: https://dalmasca.local:6443
token: ${TOKEN}
node-name: PLACEHOLDER
EOF
chmod 0600 "${ROOTFS_DIR}/etc/rancher/k3s/config.worker.yaml"
chmod 0644 "${ROOTFS_DIR}/etc/rancher/k3s/config.head.yaml"
chmod 0644 "${ROOTFS_DIR}/boot/firmware/ivalice-node.conf.template"

# --- oh-my-zsh for ivalice ---
install -d -m 0755 "${ROOTFS_DIR}/home/ivalice/.oh-my-zsh"
tar --strip-components=1 -xzf "${ASSETS}/ohmyzsh.tar.gz" \
    -C "${ROOTFS_DIR}/home/ivalice/.oh-my-zsh"
chown -R 1000:1000 "${ROOTFS_DIR}/home/ivalice/.oh-my-zsh"

on_chroot <<'CHROOT'
set -e

# --- services ---------------------------------------------------------------
systemctl enable ssh.service
systemctl enable avahi-daemon.service
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable ivalice-firstboot.service
# cloud-init 25.x renamed the main unit (cloud-init.service → cloud-init-main.service
# + cloud-init-network.service). Enabling cloud-init.target covers all 5 cloud-init
# units via the Wants= symlinks the package postinst already dropped into
# /etc/systemd/system/cloud-init.target.wants/. Future-proof against further renames.
systemctl enable cloud-init.target

# --- munge ------------------------------------------------------------------
chown munge:munge /etc/munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
systemctl enable munge.service

# --- slurm state dirs + log dir --------------------------------------------
mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chmod 0700 /var/spool/slurmctld
chmod 0755 /var/spool/slurmd /var/log/slurm
# Leave slurmctld + slurmd DISABLED; ivalice-firstboot picks one per role.
systemctl disable slurmctld.service 2>/dev/null || true
systemctl disable slurmd.service 2>/dev/null || true

# --- networking ownership --------------------------------------------------
# pi-gen's stage2 installs and enables NetworkManager unconditionally (RPi OS
# Trixie default). We own eth0 via systemd-networkd + 10-eth0.network, so NM
# would race us at boot. Disable + mask so it can't compete, and mask
# wait-online too (it would otherwise stall boot for 2min waiting on an
# unreachable NM).
systemctl disable NetworkManager.service 2>/dev/null || true
systemctl mask NetworkManager.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true

# --- default shell + editor for ivalice ------------------------------------
chsh -s /usr/bin/zsh ivalice
update-alternatives --set editor /usr/bin/nvim || true

# Switch /etc/resolv.conf to systemd-resolved's stub. Harmless if already
# pointing there.
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# --- rootless podman --------------------------------------------------------
# Give the ivalice user a subuid/subgid range so podman's user namespaces
# work without runtime provisioning. pi-gen has already created the user.
if ! grep -q '^ivalice:' /etc/subuid 2>/dev/null; then
  echo 'ivalice:100000:65536' >> /etc/subuid
fi
if ! grep -q '^ivalice:' /etc/subgid 2>/dev/null; then
  echo 'ivalice:100000:65536' >> /etc/subgid
fi

# --- kernel cgroup flags for k3s on Raspberry Pi OS -------------------------
# k3s needs memory + cpuset cgroups enabled at boot. On Pi OS these aren't
# the default, so append to cmdline.txt if not already present.
CMDLINE=/boot/firmware/cmdline.txt
if [ -f "${CMDLINE}" ] && ! grep -q 'cgroup_memory=1' "${CMDLINE}"; then
  sed -i 's|$| cgroup_memory=1 cgroup_enable=memory cgroup_enable=cpuset|' "${CMDLINE}"
fi

# --- dual k3s install (server then agent) -----------------------------------
# k3s-install.sh reads /etc/rancher/k3s/config.yaml when generating its
# systemd unit, so symlink the role-appropriate config in turn and let each
# pass drop its own unit file. Both units land DISABLED; firstboot.sh picks
# the active one per NODE_ROLE.
ln -sf /etc/rancher/k3s/config.head.yaml /etc/rancher/k3s/config.yaml
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true \
INSTALL_K3S_BIN_DIR=/usr/local/bin INSTALL_K3S_SYMLINK=skip \
  /usr/local/sbin/k3s-install.sh server

ln -sf /etc/rancher/k3s/config.worker.yaml /etc/rancher/k3s/config.yaml
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true \
INSTALL_K3S_BIN_DIR=/usr/local/bin INSTALL_K3S_SYMLINK=skip \
  /usr/local/sbin/k3s-install.sh agent

rm -f /etc/rancher/k3s/config.yaml       # firstboot will create per role

systemctl disable k3s.service       2>/dev/null || true
systemctl disable k3s-agent.service 2>/dev/null || true

# Build-time sanity: slurm units disabled, munge enabled, k3s units disabled
systemctl is-enabled munge.service | grep -q '^enabled$'
systemctl is-enabled slurmctld.service 2>/dev/null | grep -qv '^enabled$'
systemctl is-enabled slurmd.service 2>/dev/null | grep -qv '^enabled$'
systemctl list-unit-files k3s.service k3s-agent.service | grep disabled | wc -l | grep -q '^2$'
CHROOT
