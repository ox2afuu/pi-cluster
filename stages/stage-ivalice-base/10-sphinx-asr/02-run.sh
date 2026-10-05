#!/bin/bash -e
# stage-ivalice-base/10-sphinx-asr/02-run.sh
#
# Host side, after the chroot build: records the built binaries in the
# manifest, restores /etc/resolv.conf, installs the login environment, and
# hands /srv/ivalice to ivalice:ivalice (UID/GID 1000) for the NFS export.
set -euo pipefail

SPHINX_DIR="${ROOTFS_DIR}/srv/ivalice/sphinx-asr"
MANIFEST="${SPHINX_DIR}/IMAGE-MANIFEST.txt"
BIN_DIR="${SPHINX_DIR}/bin/aarch64"

if [ ! -d "${BIN_DIR}" ]; then
  echo "ERROR: ${BIN_DIR} missing after the chroot build" >&2
  exit 1
fi

# `file` runs on the build host: it is a pi-gen dependency there, and the
# image does not need it.
{
  echo
  echo "## bin/aarch64"
  (cd "${BIN_DIR}" && ls -l)
  echo
  echo "## file bin/aarch64/*"
  (cd "${BIN_DIR}" && file -- *)
} >> "${MANIFEST}"

# --- put /etc/resolv.conf back the way 00-ivalice-base left it ---------------
RESOLV="${ROOTFS_DIR}/etc/resolv.conf"
LINK_NOTE="${ROOTFS_DIR}/etc/.ivalice-resolv-link"
if [ -f "${LINK_NOTE}" ]; then
  rm -f "${RESOLV}"
  ln -s "$(cat "${LINK_NOTE}")" "${RESOLV}"
  rm -f "${LINK_NOTE}"
fi

# --- login environment --------------------------------------------------------
install -m 0644 files/sphinx-asr.sh "${ROOTFS_DIR}/etc/profile.d/sphinx-asr.sh"

# ivalice's login shell is zsh, which does not read /etc/profile.d. Source
# the snippet from the system zprofile too (sh emulation, idempotent).
ZPROFILE="${ROOTFS_DIR}/etc/zsh/zprofile"
if [ -f "${ZPROFILE}" ] && ! grep -q 'profile.d/sphinx-asr.sh' "${ZPROFILE}"; then
  cat >> "${ZPROFILE}" <<'EOF'

# sphinx-asr (stages/stage-ivalice-base/10-sphinx-asr)
[ -r /etc/profile.d/sphinx-asr.sh ] && emulate sh -c '. /etc/profile.d/sphinx-asr.sh'
EOF
fi

# --- ownership: everything under /srv/ivalice is ivalice:ivalice ---------------
# -h: the venv holds absolute symlinks (.venv/bin/python3 -> /usr/bin/python3).
# Never follow them, or chown would hit the build host's own files.
chown -R -h 1000:1000 "${ROOTFS_DIR}/srv/ivalice"
