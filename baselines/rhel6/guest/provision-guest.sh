#!/bin/bash
# baselines/rhel6/guest/provision-guest.sh
# Runs INSIDE the CentOS 6.10 guest as user "baseline" (copied in and started
# by ../provision.sh). Each phase leaves a marker in ~/.provision/ so a rerun
# resumes where it stopped. Bash 4.1 / coreutils 8.4 compatible.
#
# Usage: provision-guest.sh PHASE [PHASE...]
#   phases: packages grow-check resize python venv sphinx manifest
#   all = packages python venv sphinx manifest (grow/resize are driven by
#         provision.sh because they need a reboot in between)
#
# Toolchain rule: the sphinx-asr compute path (sphinxtrain, pocketsphinx,
# cmu_toolkit) is compiled ONLY with the system gcc 4.4.7 (/usr/bin/gcc).
# devtoolset-8 is used for one thing: building the Python 3.12 interpreter
# that runs sphinx-asr's orchestration scripts.
set -euo pipefail

STAGE="${HOME}/stage"
MARK="${HOME}/.provision"
TIMINGS="${HOME}/provision-timings.txt"
PY_PREFIX=/opt/py312
PY_VERSION=3.12.15
CMAKE_DIR=/opt/cmake-3.25.3
SPHINX_DIR="${HOME}/sphinx-asr"
SYS_CC=/usr/bin/gcc
SYS_CXX=/usr/bin/g++

mkdir -p "${MARK}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# yum over HTTPS from vault.centos.org drops connections now and then
# (curl error 18, "transfer closed"). yum keeps what it already fetched, so a
# plain retry loop converges.
yum_retry() {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if sudo yum -y -q "$@"; then
      return 0
    fi
    log "yum attempt ${i} failed; retrying"
    sleep 10
  done
  return 1
}

run_phase() {
  local phase="$1" start end
  if [ -f "${MARK}/${phase}.done" ]; then
    log "phase ${phase}: already done"
    return 0
  fi
  log "phase ${phase}: start"
  start=$(date +%s)
  "phase_${phase//-/_}"
  end=$(date +%s)
  touch "${MARK}/${phase}.done"
  echo "${phase} $((end - start))s" >> "${TIMINGS}"
  log "phase ${phase}: done in $((end - start))s"
}

phase_packages() {
  # Legacy toolchain + build deps, all from the 6.10 vault (os/updates).
  yum_retry install \
    gcc gcc-c++ cpp make binutils glibc-devel libstdc++-devel \
    perl perl-devel perl-Time-HiRes bison flex swig \
    zlib-devel bzip2 bzip2-devel xz xz-devel libffi-devel readline-devel \
    ncurses-devel gdbm-devel sqlite-devel tk-devel \
    file which tar patch diffutils time bc rsync
  # SCLo release package from vault-extras: provides the SCLo GPG key only.
  yum_retry install centos-release-scl-rh
  # Its own .repo points at the dead mirror; our vault-sclo-rh replaces it.
  sudo rm -f /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo /etc/yum.repos.d/CentOS-SCLo-scl.repo
  # Orchestration-only compiler (see header). Not on PATH by default.
  yum_retry install devtoolset-8-gcc devtoolset-8-binutils
  # kdump reserves memory and is irrelevant here.
  sudo chkconfig kdump off 2>/dev/null || true
  # cmake >= 3.25 is required by vendor/pocketsphinx; CentOS 6 has 2.8.12.
  # Kitware's static linux-x86_64 build needs only GLIBC_2.10. cmake drives
  # the build; the compiler it invokes is still /usr/bin/gcc.
  if [ ! -x "${CMAKE_DIR}/bin/cmake" ]; then
    sudo mkdir -p "${CMAKE_DIR}"
    sudo tar -xzf "${STAGE}/cmake-3.25.3-linux-x86_64.tar.gz" -C "${CMAKE_DIR}" --strip-components=1
  fi
  "${CMAKE_DIR}/bin/cmake" --version | head -1
  "${SYS_CC}" --version | head -1
}

# Grows vda1 to fill the disk and prints NEEDS_REBOOT when it did.
# cloud-utils-growpart is not in the CentOS 6.10 os/updates/extras trees
# (only EPEL), so rewrite the single-partition MBR with sfdisk instead:
# same start sector, size "rest of disk", type 83, bootable.
phase_grow_check() {
  local disk_kb part_kb start layout
  disk_kb=$(( $(cat /sys/block/vda/size) / 2 ))
  part_kb=$(( $(cat /sys/block/vda/vda1/size) / 2 ))
  if [ $((disk_kb - part_kb)) -le 1048576 ]; then
    return 0
  fi
  start=$(cat /sys/block/vda/vda1/start)
  layout=$(sudo sfdisk -d /dev/vda | grep -c 'start= *[1-9]')
  if [ "${layout}" -ne 1 ]; then
    log "unexpected partition layout; not growing"
    return 0
  fi
  log "growing vda1 (${part_kb} KiB) to fill vda (${disk_kb} KiB), start sector ${start}"
  sudo sfdisk -d /dev/vda | tee "${HOME}/vda-partition-table.before" >/dev/null
  # 2.6.32 cannot re-read the table of an in-use disk; provision.sh reboots.
  echo "${start},,83,*" | sudo sfdisk -uS --no-reread -f -q /dev/vda >/dev/null 2>&1 || true
  sudo sfdisk -d /dev/vda | grep vda1
  echo "NEEDS_REBOOT"
}

phase_resize() {
  sudo resize2fs /dev/vda1 2>&1 | tail -1 || true
  df -h /
}

phase_python() {
  # Python 3.12 needs C11 (gcc 4.4.7 only has partial C99), so it is built
  # with devtoolset-8 into an isolated prefix. No ssl/_sqlite3/_tkinter: they
  # need newer libraries than CentOS 6 ships and sphinx-asr does not use them.
  local src="${HOME}/build/Python-${PY_VERSION}"
  mkdir -p "${HOME}/build"
  rm -rf "${src}"
  tar -xJf "${STAGE}/Python-${PY_VERSION}.tar.xz" -C "${HOME}/build"
  cd "${src}"
  # The SCL enable script reads unset variables (MANPATH etc.).
  set +u
  # shellcheck disable=SC1091
  source /opt/rh/devtoolset-8/enable
  set -u
  gcc --version | head -1
  ./configure --prefix="${PY_PREFIX}" --with-ensurepip=install \
    --without-static-libpython --disable-test-modules > "${HOME}/build/python-configure.txt" 2>&1
  make -j"$(nproc)" > "${HOME}/build/python-make.txt" 2>&1
  # shellcheck disable=SC2024  # the log is meant to be owned by baseline
  sudo make install > "${HOME}/build/python-install.txt" 2>&1
  # Record which optional modules were skipped.
  grep -A20 -E 'necessary bits to build these optional modules|Failed to build these modules|not built' \
    "${HOME}/build/python-make.txt" | head -40 || true
  "${PY_PREFIX}/bin/python3.12" -c 'import sys, platform; print(sys.version); print(platform.libc_ver())'
}

phase_venv() {
  # .venv where sphinx.sh expects it; sphinx.sh skips its own pip install
  # when .venv/bin/python3 exists. Offline: no PyPI access from CentOS 6.
  rm -rf "${SPHINX_DIR}/.venv"
  mkdir -p "${SPHINX_DIR}"
  "${PY_PREFIX}/bin/python3.12" -m venv "${SPHINX_DIR}/.venv"
  "${SPHINX_DIR}/.venv/bin/pip" install -q --no-index --find-links "${STAGE}/wheelhouse" pytest pyyaml
  "${SPHINX_DIR}/.venv/bin/python3" -c 'import yaml, pytest; print("pyyaml", yaml.__version__, "libyaml", yaml.__with_libyaml__); print("pytest", pytest.__version__)'
}

phase_sphinx() {
  # Fresh tree from the git archive staged by provision.sh (keeps .venv).
  local venv_tmp=""
  if [ -d "${SPHINX_DIR}/.venv" ]; then
    venv_tmp="${HOME}/.venv.keep"
    rm -rf "${venv_tmp}"
    mv "${SPHINX_DIR}/.venv" "${venv_tmp}"
  fi
  rm -rf "${SPHINX_DIR}"
  mkdir -p "${SPHINX_DIR}"
  tar -xf "${STAGE}/sphinx-asr.tar" -C "${SPHINX_DIR}"
  if [ -n "${venv_tmp}" ]; then
    mv "${venv_tmp}" "${SPHINX_DIR}/.venv"
  fi
  cp "${STAGE}/sphinx-asr.sha" "${SPHINX_DIR}/.git-sha"
  cd "${SPHINX_DIR}"

  # vendor/cmu_toolkit/src ships prebuilt x86-64 objects (GCC 14.2, Ubuntu)
  # in git. Fresh archive mtimes make them look up to date, so make would
  # link them unchanged. Delete them so every object comes from gcc 4.4.7.
  local stale
  stale=$(find vendor -name '*.o' -o -name '*.a' | wc -l)
  log "removing ${stale} prebuilt object/archive files from vendor/"
  find vendor \( -name '*.o' -o -name '*.a' \) -delete

  # Minimal, declaration-only gcc 4.4 compatibility patches (see the header
  # of each file in baselines/rhel6/patches/). Applied to this copy only.
  local p
  for p in "${STAGE}"/patches/*.patch; do
    [ -f "${p}" ] || continue
    log "applying $(basename "${p}")"
    patch -p1 --no-backup-if-mismatch < "${p}"
  done

  export PATH="${CMAKE_DIR}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export CC="${SYS_CC}" CXX="${SYS_CXX}"
  log "compiler for compute path: $(${CC} --version | head -1)"
  make clean > "${HOME}/sphinx-make.txt" 2>&1
  local rc=0
  make >> "${HOME}/sphinx-make.txt" 2>&1 || rc=$?
  tail -25 "${HOME}/sphinx-make.txt"
  if [ "${rc}" -ne 0 ]; then
    log "make failed (rc=${rc}); first errors:"
    grep -n -E 'error|Error' "${HOME}/sphinx-make.txt" | head -40
    return "${rc}"
  fi
  ls "bin/$(uname -m)"
}

phase_manifest() {
  local out="${HOME}/TOOLCHAIN-MANIFEST.txt" bindir
  bindir="${SPHINX_DIR}/bin/$(uname -m)"
  {
    echo "# TOOLCHAIN-MANIFEST: CentOS 6.10 legacy baseline VM"
    echo "# generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') by baselines/rhel6/guest/provision-guest.sh"
    echo
    echo "## headline"
    echo "os:        $(cat /etc/redhat-release)"
    echo "kernel:    $(uname -r) ($(uname -m))"
    echo "glibc:     $(rpm -q --qf '%{VERSION}-%{RELEASE}' glibc) ($(getconf GNU_LIBC_VERSION))"
    echo "gcc:       $(${SYS_CC} --version | head -1)  [compute path]"
    echo "g++:       $(${SYS_CXX} --version | head -1)  [compute path]"
    echo "binutils:  $(ld --version | head -1)"
    echo "make:      $(make --version | head -1)"
    echo "perl:      $(perl -e 'printf "%vd", $^V')"
    echo "python2:   $(python -V 2>&1)  [system, unused by sphinx-asr]"
    echo "python3:   $(${PY_PREFIX}/bin/python3.12 -V 2>&1) at ${PY_PREFIX}  [orchestration only, built with devtoolset-8]"
    echo "dts-8 gcc: $(/opt/rh/devtoolset-8/root/usr/bin/gcc --version | head -1)  [Python build only]"
    echo "cmake:     $(${CMAKE_DIR}/bin/cmake --version | head -1)  [Kitware static binary, build driver only]"
    echo "cpu:       $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //') x $(nproc)"
    echo "sphinx-asr: $(cat "${SPHINX_DIR}/.git-sha" 2>/dev/null || echo unknown)"
    echo
    echo "## venv packages (orchestration)"
    "${SPHINX_DIR}/.venv/bin/pip" list --format=freeze 2>/dev/null || true
    echo
    echo "## compiler recorded in each built binary (.comment section)"
    if [ -d "${bindir}" ]; then
      local f
      for f in "${bindir}"/*; do
        [ -f "${f}" ] || continue
        if file "${f}" | grep -q ELF; then
          printf '%s: %s\n' "$(basename "${f}")" \
            "$(readelf -p .comment "${f}" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | sort -u | tr '\n' ';')"
        fi
      done
    fi
    echo
    echo "## file(1) output of built binaries"
    if [ -d "${bindir}" ]; then
      (cd "${bindir}" && file ./* | sed 's|^\./||')
    else
      echo "(no ${bindir}: build did not complete)"
    fi
    echo
    echo "## provision phase timings (QEMU TCG emulation, NOT valid for performance)"
    cat "${TIMINGS}" 2>/dev/null || true
    echo
    echo "## rpm -qa (sorted)"
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort
  } > "${out}"
  sed -n '1,20p' "${out}"
}

[ $# -gt 0 ] || { sed -n '2,16p' "$0"; exit 2; }
for p in "$@"; do
  case "${p}" in
    all) for q in packages python venv sphinx manifest; do run_phase "${q}"; done ;;
    grow-check) phase_grow_check ;;
    resize) phase_resize ;;
    manifest) phase_manifest ;;
    packages|python|venv|sphinx) run_phase "${p}" ;;
    *) echo "unknown phase: ${p}" >&2; exit 2 ;;
  esac
done
