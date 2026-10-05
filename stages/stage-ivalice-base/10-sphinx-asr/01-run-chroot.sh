# shellcheck shell=bash
# stage-ivalice-base/10-sphinx-asr/01-run-chroot.sh
#
# Piped by pi-gen into `bash -e` inside the target rootfs (no shebang:
# pi-gen runs it with on_chroot < 01-run-chroot.sh).
#
# Builds the vendored CMU tools natively for aarch64 into bin/aarch64/ and
# creates the runtime venv, so nothing is compiled or pip-installed after
# boot (the cluster is airgapped). The build dependencies (build-essential,
# cmake, python3-venv) are already in 00-ivalice-base/00-packages as part
# of the image's development toolset, so none are installed or purged here.
set -euo pipefail

SPHINX_ROOT=/srv/ivalice/sphinx-asr
MANIFEST="${SPHINX_ROOT}/IMAGE-MANIFEST.txt"
cd "${SPHINX_ROOT}"

# --- vendor build: bin/aarch64/ -------------------------------------------
# 00-run.sh exported a pristine tree and deleted the committed x86 objects;
# `make clean` also drops any cmake build trees, so nothing is reused.
make clean
make

if [ ! -x "bin/$(uname -m)/sphinx_fe" ]; then
  echo "ERROR: make did not produce bin/$(uname -m)/sphinx_fe" >&2
  exit 1
fi

# The build trees are only needed to produce bin/; keep the image lean.
rm -rf vendor/sphinxtrain/build vendor/pocketsphinx/build
find vendor/cmu_toolkit -type f \( -name '*.o' -o -name '*.a' \) -delete

# --- runtime venv ---------------------------------------------------------
# sphinx.sh only creates .venv (and pip-installs) when .venv/bin/python3 is
# missing, so a venv built here means no network access at runtime.
python3 -m venv .venv
.venv/bin/python3 -m pip install --no-cache-dir --disable-pip-version-check \
  -r requirements.txt
.venv/bin/python3 -c 'import numpy, scipy, yaml'

# `sphinx` on PATH for everyone (the Makefile's `link` target, done here).
ln -sf "${SPHINX_ROOT}/sphinx.sh" /usr/local/bin/sphinx

# --- manifest: toolchain and Python environment ---------------------------
{
  echo "arch: $(uname -m)"
  echo "gcc: $(gcc --version | head -n 1)"
  echo "cmake: $(cmake --version | head -n 1)"
  echo "perl: $(perl -e 'print $^V')"
  echo "python: $(python3 --version 2>&1)"
  echo "venv_python: $(.venv/bin/python3 --version 2>&1)"
  echo
  echo "## pip freeze (.venv)"
  .venv/bin/python3 -m pip freeze --disable-pip-version-check
} >> "${MANIFEST}"
