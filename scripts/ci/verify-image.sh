#!/usr/bin/env bash
#
# scripts/ci/verify-image.sh
#
# Offline checks of a built ivalice image. Attaches the image read-only
# with `losetup -P`, mounts the root partition read-only, and checks the OS,
# the sphinx-asr payload and the systemd unit defaults. Results go to
# stdout as TAP and, with --junit, to a JUnit XML file for GitLab's
# artifacts:reports:junit. Runs on the `pigen-builder` runner (native
# aarch64, passwordless sudo); see docs/infra/lab-image.md.
#
# Usage:
#   scripts/ci/verify-image.sh [--manifest FILE] [--junit FILE] [--tap FILE] IMAGE
#
#   IMAGE           the .img, or the .img.xz that scripts/ci/build-image.sh
#                   writes (decompressed into a temp dir first)
#   --manifest F    image-manifest.json from build-image.sh. Supplies the
#                   expected sphinx-asr commit and image sha256. Without it,
#                   the expected commit is <repo>/sphinx-asr's HEAD.
#   --junit F       also write JUnit XML to F
#   --tap F         also write the TAP stream to F
#
# The image is never modified: the root partition is mounted ro,noload,
# chroot commands get tmpfs /tmp and /run, and pytest comes from a
# throwaway --target directory on the host copied into that tmpfs. Fetching
# pytest needs network access on the host.
#
# Environment:
#   TMPDIR   where the temp dir (and a decompressed image) goes
#            (default: /var/tmp)
#
# Exit codes:
#   0  every check passed
#   1  at least one check failed
#   2  usage error
#   3  setup error (missing tool, no sudo, image could not be attached
#      or mounted, pytest could not be fetched)
set -euo pipefail
# losetup, chroot and friends live in sbin, which is not on an unprivileged
# runner user's PATH on Debian.
export PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPHINX_ROOT=/srv/ivalice/sphinx-asr

# bin/aarch64 tools the sphinx-asr Makefile installs: the three pocketsphinx
# binaries it copies by name, cmu_toolkit's EXECS, and the sphinxtrain
# executables found at the top of its build tree (as built at 7745786).
EXPECTED_TOOLS=(
  pocketsphinx pocketsphinx_batch pocketsphinx_lm_convert
  idngram2lm evallm text2wngram text2idngram binlm2arpa ngram2mgram
  idngram2stats wfreq2vocab text2wfreq wngram2idngram mergeidngram interpolate
  sphinx_fe sphinx_cepview sphinx3_align bw norm agg_seg bldtree cdcn_norm
  cdcn_train cp_parm delint inc_comp init_gau init_mixw kdtree kmeans_init
  make_quests map_adapt mixw_interp mk_flat mk_mdef_gen mk_mllr_class
  mk_s2sendump mk_ts2cb mllr_solve mllr_transform param_cnt printp
  prunetree tiestate
)

usage() { sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
setup_fail() { printf 'SETUP ERROR: %s\n' "$*" >&2; exit 3; }

MANIFEST="" JUNIT="" TAP_FILE="" IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a file}"; shift 2 ;;
    --junit) JUNIT="${2:?--junit needs a file}"; shift 2 ;;
    --tap) TAP_FILE="${2:?--tap needs a file}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "${IMAGE}" ] || usage; IMAGE="$1"; shift ;;
  esac
done
[ -n "${IMAGE}" ] || usage
[ -f "${IMAGE}" ] || setup_fail "image not found: ${IMAGE}"
[ -z "${MANIFEST}" ] || [ -f "${MANIFEST}" ] || setup_fail "manifest not found: ${MANIFEST}"

for tool in sudo losetup lsblk mount umount chroot file jq sha256sum xz python3; do
  command -v "${tool}" >/dev/null 2>&1 || setup_fail "missing tool: ${tool}"
done
sudo -n true 2>/dev/null || setup_fail "passwordless sudo is required"

TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/ivalice-verify.XXXXXX")"
MNT="${TMP}/root"
LOOP=""

cleanup() {
  local rc=$?
  set +e
  if mountpoint -q "${MNT}" 2>/dev/null; then
    sudo umount -R "${MNT}" || sudo umount -R -l "${MNT}"
  fi
  [ -n "${LOOP}" ] && sudo losetup -d "${LOOP}"
  if awk -v m="${TMP}/" 'index($2, m) == 1 {f=1} END {exit !f}' /proc/self/mounts; then
    echo "WARNING: mounts remain under ${TMP}; not removing it" >&2
  else
    rm -rf "${TMP}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

# --- results: TAP to stdout, JUnit at the end --------------------------------
N=0
FAILS=0
TAP_LINES=()
J_CLASS=() J_NAME=() J_MSG=()

record() { # record <pass|fail> <group> <name> [message]
  local status="$1" group="$2" name="$3" msg="${4:-}" line
  N=$((N + 1))
  if [ "${status}" = pass ]; then
    line="ok ${N} - ${group}: ${name}"
  else
    FAILS=$((FAILS + 1))
    line="not ok ${N} - ${group}: ${name}"
  fi
  printf '%s\n' "${line}"
  TAP_LINES+=("${line}")
  if [ "${status}" != pass ] && [ -n "${msg}" ]; then
    while IFS= read -r l; do
      printf '  # %s\n' "${l}"
      TAP_LINES+=("  # ${l}")
    done < <(printf '%s\n' "${msg}" | head -n 40)
  fi
  J_CLASS+=("verify-image.${group}")
  J_NAME+=("${name}")
  if [ "${status}" = pass ]; then J_MSG+=(""); else J_MSG+=("${msg:-failed}"); fi
}

# check <group> <name> <command...>: pass when the command exits 0; its
# output becomes the failure message.
check() {
  local group="$1" name="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    record pass "${group}" "${name}"
  else
    record fail "${group}" "${name}" "${out}"
  fi
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' \
    | tr -d '\000-\010\013\014\016-\037'
}

write_junit() {
  local i
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    printf '<testsuites name="verify-image" tests="%d" failures="%d">\n' "${N}" "${FAILS}"
    printf '<testsuite name="verify-image" tests="%d" failures="%d">\n' "${N}" "${FAILS}"
    for i in "${!J_NAME[@]}"; do
      printf '<testcase classname="%s" name="%s">' \
        "$(printf '%s' "${J_CLASS[$i]}" | xml_escape)" \
        "$(printf '%s' "${J_NAME[$i]}" | xml_escape)"
      if [ -n "${J_MSG[$i]}" ]; then
        printf '<failure message="%s">%s</failure>' \
          "$(printf '%s' "${J_MSG[$i]}" | head -n 1 | xml_escape)" \
          "$(printf '%s' "${J_MSG[$i]}" | xml_escape)"
      fi
      printf '</testcase>\n'
    done
    echo '</testsuite>'
    echo '</testsuites>'
  } > "${JUNIT}"
}

# --- chroot helpers -----------------------------------------------------------
CHROOT_ENV=(env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  HOME=/tmp LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1)
in_root() { sudo chroot "${MNT}" "${CHROOT_ENV[@]}" "$@"; }
in_user() { sudo chroot --userspec=1000:1000 "${MNT}" "${CHROOT_ENV[@]}" USER=ivalice LOGNAME=ivalice "$@"; }

# --- attach and mount -----------------------------------------------------------
echo "# image: ${IMAGE}"
RAW="${IMAGE}"
case "${IMAGE}" in
  *.xz)
    RAW="${TMP}/image.img"
    echo "# decompressing to ${RAW}"
    xz -dc -T0 "${IMAGE}" > "${RAW}" || setup_fail "xz -d failed"
    ;;
esac

LOOP="$(sudo losetup --find --show --partscan --read-only "${RAW}")" \
  || setup_fail "losetup failed"
if command -v udevadm >/dev/null 2>&1; then sudo udevadm settle -t 10 || true; fi
ROOT_DEV=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ROOT_DEV="$(lsblk -nrpo NAME,LABEL "${LOOP}" | awk '$2 == "rootfs" {print $1; exit}')"
  [ -z "${ROOT_DEV}" ] && [ -b "${LOOP}p2" ] && ROOT_DEV="${LOOP}p2"
  [ -n "${ROOT_DEV}" ] && break
  sleep 1
done
[ -n "${ROOT_DEV}" ] || setup_fail "no root partition found on ${LOOP}"

mkdir -p "${MNT}"
sudo mount -o ro,noload "${ROOT_DEV}" "${MNT}" || setup_fail "mount ${ROOT_DEV} failed"
sudo mount -t proc proc "${MNT}/proc"
sudo mount --bind /dev "${MNT}/dev"
sudo mount -t tmpfs -o mode=1777 tmpfs "${MNT}/tmp"
sudo mount -t tmpfs -o mode=0755 tmpfs "${MNT}/run"

echo "# pytest into a throwaway target dir (host side)"
python3 -m venv "${TMP}/pip-venv" >/dev/null || setup_fail "python3 -m venv failed"
"${TMP}/pip-venv/bin/pip" install --quiet --disable-pip-version-check \
  --target "${TMP}/pytest-site" pytest || setup_fail "pip install pytest failed"
sudo cp -a "${TMP}/pytest-site" "${MNT}/tmp/pytest-site"
sudo chmod -R a+rX "${MNT}/tmp/pytest-site"

# --- expected values from the manifest ------------------------------------------
EXPECTED_SHA=""
EXPECTED_IMG_SHA=""
if [ -n "${MANIFEST}" ]; then
  EXPECTED_SHA="$(jq -r '.submodules["sphinx-asr"] // empty' "${MANIFEST}")"
  EXPECTED_IMG_SHA="$(jq -r '.image.sha256 // empty' "${MANIFEST}")"
elif [ -e "${REPO_ROOT}/sphinx-asr/.git" ]; then
  EXPECTED_SHA="$(git -C "${REPO_ROOT}/sphinx-asr" rev-parse HEAD)"
fi

# ===================================================================================
# Checks
# ===================================================================================

# --- image integrity ---------------------------------------------------------------
if [ -n "${EXPECTED_IMG_SHA}" ]; then
  img_sha_matches() {
    local got
    got="$(sha256sum "${RAW}" | awk '{print $1}')"
    [ "${got}" = "${EXPECTED_IMG_SHA}" ] || { echo "sha256 ${got}, manifest says ${EXPECTED_IMG_SHA}"; return 1; }
  }
  check image "raw image sha256 matches image-manifest.json" img_sha_matches
fi

# --- os ------------------------------------------------------------------------------
os_is_trixie() {
  local codename
  # shellcheck disable=SC1091
  codename="$(. "${MNT}/etc/os-release" && printf '%s' "${VERSION_CODENAME:-}")"
  [ "${codename}" = trixie ] || { echo "VERSION_CODENAME=${codename}"; return 1; }
}
check os "/etc/os-release is Debian trixie" os_is_trixie

dpkg_arch_is_arm64() {
  local arch
  arch="$(in_root dpkg --print-architecture)"
  [ "${arch}" = arm64 ] || { echo "dpkg architecture ${arch}"; return 1; }
}
check os "dpkg architecture is arm64" dpkg_arch_is_arm64

userland_is_aarch64() {
  local f
  f="$(file -bL "${MNT}/usr/bin/dpkg")"
  case "${f}" in *"ARM aarch64"*) ;; *) echo "${f}"; return 1 ;; esac
}
check os "/usr/bin/dpkg is an aarch64 ELF" userland_is_aarch64

# --- sphinx-asr tree ---------------------------------------------------------------
check sphinx-asr "${SPHINX_ROOT} exists" test -d "${MNT}${SPHINX_ROOT}"
check sphinx-asr "IMAGE-MANIFEST.txt exists" test -s "${MNT}${SPHINX_ROOT}/IMAGE-MANIFEST.txt"

sha_matches() {
  local got
  [ -n "${EXPECTED_SHA}" ] || { echo "no expected sha (pass --manifest)"; return 1; }
  got="$(awk -F': ' '/^sphinx_asr_commit:/ {print $2; exit}' "${MNT}${SPHINX_ROOT}/IMAGE-MANIFEST.txt")"
  [ "${got}" = "${EXPECTED_SHA}" ] || { echo "image has ${got:-nothing}, expected ${EXPECTED_SHA}"; return 1; }
}
check sphinx-asr "tree is at the pinned commit ${EXPECTED_SHA:0:12}" sha_matches
check sphinx-asr "no .git directory in the exported tree" test ! -e "${MNT}${SPHINX_ROOT}/.git"

owned_by_ivalice() {
  local top bad
  top="$(stat -c %u:%g "${MNT}/srv/ivalice")"
  [ "${top}" = 1000:1000 ] || { echo "/srv/ivalice is ${top}"; return 1; }
  bad="$(sudo find "${MNT}/srv/ivalice" \( ! -uid 1000 -o ! -gid 1000 \) -print 2>&1 | head -n 5)"
  [ -z "${bad}" ] || { echo "not 1000:1000:"; echo "${bad}"; return 1; }
}
check sphinx-asr "/srv/ivalice is owned 1000:1000 recursively" owned_by_ivalice

# --- bin/aarch64 ---------------------------------------------------------------------
BIN="${MNT}${SPHINX_ROOT}/bin/aarch64"
tool_ok() {
  local path="${BIN}/$1" f missing
  if [ ! -f "${path}" ] || [ ! -x "${path}" ]; then
    echo "missing or not executable"; return 1
  fi
  f="$(file -b "${path}")"
  case "${f}" in *"ELF 64-bit"*"ARM aarch64"*) ;; *) echo "${f}"; return 1 ;; esac
  missing="$(in_root ldd "${SPHINX_ROOT}/bin/aarch64/$1" 2>&1 | grep 'not found' || true)"
  [ -z "${missing}" ] || { echo "unresolved libraries:"; echo "${missing}"; return 1; }
}
for t in "${EXPECTED_TOOLS[@]}"; do
  check bin "bin/aarch64/${t} is an aarch64 ELF with resolvable libraries" tool_ok "${t}"
done

all_bins_aarch64() {
  local p f bad=""
  for p in "${BIN}"/*; do
    f="$(file -b "${p}")"
    case "${f}" in *"ARM aarch64"*) ;; *) bad="${bad}$(basename "${p}"): ${f}"$'\n' ;; esac
  done
  [ -z "${bad}" ] || { printf '%s' "${bad}"; return 1; }
}
check bin "every file in bin/aarch64 is aarch64" all_bins_aarch64

# --- venv, environment, sphinx.sh -----------------------------------------------------
check venv ".venv/bin/python3 exists (sphinx.sh will not pip install)" \
  in_root test -x "${SPHINX_ROOT}/.venv/bin/python3"
check venv "venv imports yaml, numpy, scipy" \
  in_user "${SPHINX_ROOT}/.venv/bin/python3" -c 'import yaml, numpy, scipy'

sphinx_sh_offline() {
  local out
  out="$(in_user "${SPHINX_ROOT}/sphinx.sh" 2>&1 || true)"
  case "${out}" in
    *"Creating python virtual environment"*|*"Installing python dependencies"*)
      echo "${out}"; return 1 ;;
  esac
  case "${out}" in *"Usage: sphinx.sh"*) ;; *) echo "${out}"; return 1 ;; esac
}
check venv "sphinx.sh runs without creating a venv" sphinx_sh_offline

login_env() {
  local out
  # The inner shell expands $SPHINX_ROOT, not this one.
  # shellcheck disable=SC2016
  out="$(in_user sh -c '. /etc/profile.d/sphinx-asr.sh && echo "$SPHINX_ROOT" && command -v sphinx_fe && command -v python3')"
  [ "${out}" = "${SPHINX_ROOT}
${SPHINX_ROOT}/bin/aarch64/sphinx_fe
${SPHINX_ROOT}/.venv/bin/python3" ] || { echo "${out}"; return 1; }
}
check venv "/etc/profile.d/sphinx-asr.sh sets SPHINX_ROOT and PATH for ivalice" login_env
check venv "/etc/zsh/zprofile sources the sphinx-asr profile" \
  grep -q 'profile.d/sphinx-asr.sh' "${MNT}/etc/zsh/zprofile"

run_pytest() {
  in_user sh -c "cd ${SPHINX_ROOT} && PYTHONPATH=/tmp/pytest-site \
    .venv/bin/python3 -m pytest -q -p no:cacheprovider tests"
}
check pytest "sphinx-asr test suite passes in the image venv" run_pytest

# --- systemd unit defaults (the build-time asserts in 00-ivalice-base/01-run.sh) ----
unit_state() { in_root systemctl is-enabled "$1" 2>/dev/null || true; }
unit_is() {
  local got
  got="$(unit_state "$1")"
  [ "${got}" = "$2" ] || { echo "$1 is '${got}', expected '$2'"; return 1; }
}
unit_is_not() {
  local got
  got="$(unit_state "$1")"
  [ "${got}" != "$2" ] || { echo "$1 is '${got}'"; return 1; }
}
check units "munge.service enabled" unit_is munge.service enabled
check units "slurmctld.service not enabled" unit_is_not slurmctld.service enabled
check units "slurmd.service not enabled" unit_is_not slurmd.service enabled
k3s_both_disabled() {
  local n
  n="$(in_root systemctl list-unit-files k3s.service k3s-agent.service | grep -c disabled || true)"
  [ "${n}" = 2 ] || { in_root systemctl list-unit-files k3s.service k3s-agent.service; return 1; }
}
check units "k3s.service and k3s-agent.service disabled" k3s_both_disabled
check units "ivalice-firstboot.service enabled" unit_is ivalice-firstboot.service enabled

# --- report ---------------------------------------------------------------------------
echo "1..${N}"
TAP_LINES+=("1..${N}")
[ -z "${TAP_FILE}" ] || printf '%s\n' "${TAP_LINES[@]}" > "${TAP_FILE}"
[ -z "${JUNIT}" ] || write_junit
echo "# ${FAILS} of ${N} checks failed"
[ "${FAILS}" -eq 0 ]
