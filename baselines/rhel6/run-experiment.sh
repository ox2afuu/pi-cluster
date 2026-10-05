#!/usr/bin/env bash
# baselines/rhel6/run-experiment.sh
# HOOK, NOT YET EXERCISED: no speech corpus is staged on the build host, so
# this has never run end to end. It stages a corpus into the guest and runs
# the standard sphinx-asr pipeline with the gcc 4.4.7 binaries, then copies
# the decode summary back for comparison with the Pi cluster.
#
# Usage: ./run-experiment.sh CORPUS_NAME CORPUS_DIR [FEATS_SPLIT]
#   CORPUS_NAME  name of an existing sphinx-asr corpus definition
#                (sphinx-asr/corpus/<name>/corpus.yml, e.g. librispeech)
#   CORPUS_DIR   host directory whose contents belong next to corpus.yml:
#                the split directories (e.g. dev-clean/), and the dict/ and
#                lm/ files that corpus.yml names
#   FEATS_SPLIT  split to pre-extract features for (default: all)
#
# Results land in results/experiments/<UTC timestamp>-<CORPUS_NAME>/.
# Comparable outputs: WER/SER and the model files; NOT wall-clock time
# under TCG (see README.md). LDA/MLLT steps need numpy/scipy, which this
# VM does not provide; keep them disabled in experiment.yml (the template
# default, CFG_LDA_MLLT "no"). Corpora with audio_type sox (LibriSpeech
# flac) also need `sudo yum install sox` in the guest first; whether
# CentOS 6's sox 14.2 decodes flac has not been checked.
set -euo pipefail

# shellcheck source=_common.sh
. "$(dirname "$0")/_common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }
[[ $# -ge 2 ]] || usage
corpus="$1"
src="$2"
split="${3:-all}"
[[ "${corpus}" =~ ^[A-Za-z0-9_-]+$ ]] || die "bad corpus name: ${corpus}"
[[ -d "${src}" ]] || die "corpus dir not found: ${src}"
[[ -f "${REPO_ROOT}/sphinx-asr/corpus/${corpus}/corpus.yml" ]] \
  || die "no sphinx-asr/corpus/${corpus}/corpus.yml in the pinned submodule"
vm_ssh -o BatchMode=yes true 2>/dev/null || die "VM not reachable; run ./vm.sh up first"

out="${RESULTS_DIR}/experiments/$(date -u +%Y%m%dT%H%M%SZ)-${corpus}"
mkdir -p "${out}"

log "staging ${src} into the guest (scp; this is slow for large corpora)"
scp -r "${SCP_OPTS[@]}" "${src}/." "${VM_USER}@${SSH_BIND}:sphinx-asr/corpus/${corpus}/"

# Remote: run the pipeline exactly as on the Pi cluster, in local mode
# (no qsub/sbatch on PATH).
vm_ssh "bash -s ${corpus} ${split}" <<'GUEST' | tee "${out}/pipeline.txt"
set -euo pipefail
corpus="$1"; split="$2"
cd ~/sphinx-asr
./sphinx.sh feats "${corpus}" "${split}"
./sphinx.sh new -t "${corpus}"
exp=$(ls -d experiments/* | sort | tail -1)
./sphinx.sh setup "${exp}"
./sphinx.sh train "${exp}"
./sphinx.sh decode "${exp}"
echo "EXPERIMENT_DIR=${exp}"
GUEST

exp_dir="$(sed -n 's/^EXPERIMENT_DIR=//p' "${out}/pipeline.txt" | tail -1)"
[[ -n "${exp_dir}" ]] && vm_scp_from "sphinx-asr/${exp_dir}/experiment.yml" "${out}/" || true
log "done; outputs in ${out}"
