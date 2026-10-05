# shellcheck shell=sh
# /etc/profile.d/sphinx-asr.sh
# Installed by stages/stage-ivalice-base/10-sphinx-asr/02-run.sh; also
# sourced from /etc/zsh/zprofile because ivalice's login shell is zsh.
#
# SPHINX_ROOT for every login; the prebuilt tools and the venv go on PATH
# for the ivalice user only, so root keeps the system python3.
SPHINX_ROOT=/srv/ivalice/sphinx-asr
export SPHINX_ROOT

if [ "$(id -un 2>/dev/null)" = "ivalice" ]; then
    case ":${PATH}:" in
        *":${SPHINX_ROOT}/bin/aarch64:"*) ;;
        *) PATH="${SPHINX_ROOT}/.venv/bin:${SPHINX_ROOT}/bin/aarch64:${PATH}" ;;
    esac
    export PATH
fi
