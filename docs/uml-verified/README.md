# UML documentation: Pi-Gen imaging, CMU Sphinx, and sphinx-asr

Generated 2026-10-05 from the code in `cmCluster/` (imported into this wiki from the standalone `uml-docs/` directory) and checked line by line against it:

- `ivaliceCluster` @ 9c6c4aa
- pi-gen submodule @ d2f70c5
- `sphinx-asr` @ 1aa0441 (identical in `sphinx-asr-standalone`, `CMUSphinx_ClusterIntegration/sphinx-asr`, and `ivaliceCluster/sphinx-asr`)

The diagrams are PlantUML `.puml` sources with matching `.svg` and `.png` renders. In this wiki each package has a generated gallery page (linked under each heading below) with every render, zoomable, and its source.

Re-render with:

```sh
plantuml -tsvg docs/uml-verified/*/*.puml   # from the repo root
plantuml -tpng docs/uml-verified/*/*.puml
```

`_style.iuml` holds the shared look. The diagrams are black and white except for pink notes, which flag a **FINDING**: a place where the code disagrees with the docs, a latent bug, or a risk.

This set sits beside the older [Phase 0 package](../uml/README.md) (`docs/uml/`) and doesn't replace it. That package still has diagrams this one doesn't cover: the proposed Slurm integration (04) and federation (05). Its drift is listed at the bottom.

## 01-pigen-imaging: how the cluster image is built and brought up

Gallery with every render and source: [01-pigen-imaging](01-pigen-imaging/index.md).

| File | Type | Shows |
|---|---|---|
| [01a-deployment-build-host](01-pigen-imaging/index.md#01a-deployment-build-host) | deployment | Where each piece runs: macOS host, rootful podman VM, privileged pi-gen container, its three bind mounts, and the SD card |
| [01b-activity-build-sh](01-pigen-imaging/index.md#01b-activity-build-sh) | activity | `scripts/build.sh` end to end: assets, keys, pubkey resolution, `run_pigen` preflight, and the podman build/run/copy steps |
| [01c-sequence-run-pigen](01-pigen-imaging/index.md#01c-sequence-run-pigen) | sequence | Messages between operator, helper, VM, podman, container, and pi-gen |
| [01d-activity-pigen-stage-engine](01-pigen-imaging/index.md#01d-activity-pigen-stage-engine) | activity | How upstream pi-gen runs STAGE_LIST, sub-stages (`NN-debconf`, packages, patches, `run.sh`, `run-chroot.sh`), and export-image |
| [01e-component-stage-layering](01-pigen-imaging/index.md#01e-component-stage-layering) | component | What stage0, stage1, stage2, `stage-ivalice-base`, and export-image each add to the rootfs |
| [01f-deployment-image-contents](01-pigen-imaging/index.md#01f-deployment-image-contents) | deployment | What the unified `ivalice.img` contains: bootfs, `/etc`, `/opt`, home directory, and systemd unit states |
| [01g-activity-flash-personalize](01-pigen-imaging/index.md#01g-activity-flash-personalize) | activity | Flashing, then `personalize-node.sh` modes, validation, writing `ivalice-node.conf`, the ledger, and eject |
| [01h-state-node-lifecycle](01-pigen-imaging/index.md#01h-state-node-lifecycle) | state | A node's states: built, flashed, personalized, first-booted, running, converging, verified, retry/fail |
| [01i-sequence-firstboot](01-pigen-imaging/index.md#01i-sequence-firstboot) | sequence | systemd ordering on first boot and role dispatch for head vs worker |
| [01j-sequence-ansible-convergence](01-pigen-imaging/index.md#01j-sequence-ansible-convergence) | sequence | Head post-boot: worker quorum wait, then `site.yml` playbooks 10, 20, 30, 40/50, 90 |
| [01k-deployment-runtime-cluster](01-pigen-imaging/index.md#01k-deployment-runtime-cluster) | deployment | Runtime topology: 6 nodes, IPs, Slurm/munge/k3s services and ports |

## 02-cmu-sphinx-reference: how upstream CMU Sphinx is meant to work

Gallery with every render and source: [02-cmu-sphinx-reference](02-cmu-sphinx-reference/index.md).

| File | Type | Shows |
|---|---|---|
| [02a-component-toolchain](02-cmu-sphinx-reference/index.md#02a-component-toolchain) | component | SphinxTrain (Perl, C, Python, Queue), PocketSphinx, CMU SLM toolkit, scoring, and their file contracts |
| [02b-activity-e2e-pipeline](02-cmu-sphinx-reference/index.md#02b-activity-e2e-pipeline) | activity | Corpus to features and LM, then AM training, decode, and WER |
| [02c-class-experiment-layout](02-cmu-sphinx-reference/index.md#02c-class-experiment-layout) | class | The `$CFG_BASE_DIR` directory contract and which step reads or writes what |
| [02d-state-acoustic-model](02-cmu-sphinx-reference/index.md#02d-state-acoustic-model) | state | AM lifecycle through steps 00 to 90, with the actual skip guards |
| [02e-sequence-baum-welch-control](02-cmu-sphinx-reference/index.md#02e-sequence-baum-welch-control) | sequence | Real control flow: queued bw parts, then `norm_and_launchbw`, which recursively starts the next iteration, while the caller polls logs |
| [02f-activity-convergence-splitting](02-cmu-sphinx-reference/index.md#02f-activity-convergence-splitting) | activity | Convergence-ratio, min/max-iteration, and Gaussian-splitting logic |
| [02g-class-queue](02-cmu-sphinx-reference/index.md#02g-class-queue) | class | `Queue`, `Queue::POSIX`, `Queue::PBS`, `Queue::Job`, plus the proposed `Queue::Slurm` (the seam for cluster parallelism) |
| [02h-sequence-decode](02-cmu-sphinx-reference/index.md#02h-sequence-decode) | sequence | `decode/slave.pl`, then `psdecode.pl` x N, `pocketsphinx_batch`, concat, `word_align`, WER |
| [02i-activity-feature-extraction](02-cmu-sphinx-reference/index.md#02i-activity-feature-extraction) | activity | `sphinx_fe` front end to 13 cepstra, then CMN, deltas, and LDA/MLLT to the feature vector |

## 03-sphinx-asr-mason: Mason Armand's customizations

Gallery with every render and source: [03-sphinx-asr-mason](03-sphinx-asr-mason/index.md).

| File | Type | Shows |
|---|---|---|
| [03a-component-architecture](03-sphinx-asr-mason/index.md#03a-component-architecture) | component | `sphinx.sh`, venv, scripts, `lib`, corpus adapters, YAML, vendor, `bin/<arch>`, experiments |
| [03b-class-config-model](03-sphinx-asr-mason/index.md#03b-class-config-model) | class | `experiment.yml` / `corpus.yml` schema, `config.py` API, adapter interface, dataclasses |
| [03c-sequence-new-setup](03-sphinx-asr-mason/index.md#03c-sequence-new-setup) | sequence | `sphinx new` and `sphinx setup`: YAML to fileids, transcription, dic, phone, filler, `feat.params`, cfg |
| [03d-activity-cfg-generation](03-sphinx-asr-mason/index.md#03d-activity-cfg-generation) | activity | `sphinx_train.cfg` generation and override precedence, including `_to_perl_value` |
| [03e-activity-feats](03-sphinx-asr-mason/index.md#03e-activity-feats) | activity | `sphinx feats`: thread pool, `.mfc` cache, input-format dispatch |
| [03f-sequence-train](03-sphinx-asr-mason/index.md#03f-sequence-train) | sequence | `sphinx train`: 13 Perl steps, MLLT seed env var, artifact and log validation, `--from-step` |
| [03g-sequence-decode](03-sphinx-asr-mason/index.md#03g-sequence-decode) | sequence | `sphinx decode`: progress-polling thread, the psdecode `-ldadim` patch, WER |
| [03h-activity-lm](03-sphinx-asr-mason/index.md#03h-activity-lm) | activity | `sphinx lm` and the CMU SLM toolkit chain |
| [03i-component-build-vendor-patches](03-sphinx-asr-mason/index.md#03i-component-build-vendor-patches) | component | Makefile targets and every patch to vendored upstream code (with commits) |
| [03j-deployment-docker-vs-venv](03-sphinx-asr-mason/index.md#03j-deployment-docker-vs-venv) | deployment | The removed multi-stage Dockerfile (Mar 24-26 2026) vs the current native build + venv |
| [03k-deployment-cluster-integration-gap](03-sphinx-asr-mason/index.md#03k-deployment-cluster-integration-gap) | deployment | How sphinx-asr would run on the ivalice cluster, and what is missing today |

## Findings, ranked by impact

"Likely" means the reading of the code is solid but should be confirmed on the hardware.

**Blocks a working cluster build or bring-up**

- **1. pi-gen pin is 32-bit.** The ivaliceCluster `pi-gen` submodule points at `master` (`ARCH=armhf`), but `config.base` and every arm64 asset assume the `arm64` branch. `cmCluster/pi-gen` is on `arm64`. ([01a](01-pigen-imaging/index.md#01a-deployment-build-host))
- **2. Workers have no passwordless sudo (likely).** Ansible uses `become` as `ivalice`, but `PASSWORDLESS_SUDO=1` is not set in `config.base` (pi-gen defaults to 0). Every privileged task on the workers should fail. ([01j](01-pigen-imaging/index.md#01j-sequence-ansible-convergence))
- **3. Missing Ansible collections (likely).** `ansible.cfg` uses `stdout_callback = yaml` (community.general) and the common role uses `ansible.posix.sysctl`. Debian's `ansible-core` ships neither collection. ([01j](01-pigen-imaging/index.md#01j-sequence-ansible-convergence))
- **4. Partition named "default" (likely).** `slurm.conf` declares `PartitionName=default`, which Slurm reads as the defaults record, not a real partition. ([01k](01-pigen-imaging/index.md#01k-deployment-runtime-cluster))
- **5. Services enabled on first boot don't start that boot (likely).** Units that firstboot enables mid-boot normally start only on the next boot. Expect one extra power cycle. ([01i](01-pigen-imaging/index.md#01i-sequence-firstboot))
- **6. NFS is documented but not built.** `/srv/ivalice` appears in the docs, but there are no NFS packages, exports, or mounts, and no sphinx-asr stage or playbook. The image does not contain sphinx-asr. ([01f](01-pigen-imaging/index.md#01f-deployment-image-contents), [03k](03-sphinx-asr-mason/index.md#03k-deployment-cluster-integration-gap))
- **7. k3s pod network overlaps the node LAN.** k3s's default cluster-cidr (10.42.0.0/16) contains the node subnet 10.42.0.0/24. ([01k](01-pigen-imaging/index.md#01k-deployment-runtime-cluster))
- **8. Quorum and verify disagree.** The wait-for-workers quorum is 3/5, but verify needs 5/5. Because of a misplaced `StartLimitIntervalSec`, the service probably retries every 2 minutes forever. ([01h](01-pigen-imaging/index.md#01h-state-node-lifecycle), [01j](01-pigen-imaging/index.md#01j-sequence-ansible-convergence))
- **9. README commands are wrong.** The quick start's `personalize-node.sh --hostname/--ip/--role` flags don't exist, and the script needs bash 4+, which macOS doesn't ship. ([01g](01-pigen-imaging/index.md#01g-activity-flash-personalize))

**Affects experiment validity (thesis-relevant)**

- **10. Optimistic WER.** `setup.py` removes every decode utterance that contains an out-of-vocabulary word, so WER is measured on an in-vocabulary subset. ([03c](03-sphinx-asr-mason/index.md#03c-sequence-new-setup))
- **11. Training failures are silently skipped.** `train.py` only stops on a non-zero exit for steps 01 and 02. Any other failed step prints a WARNING and training continues. ([03f](03-sphinx-asr-mason/index.md#03f-sequence-train))
- **12. Front end comes from the first corpus only.** In a mixed-corpus experiment, setup takes CMN, sample rate, filterbank, `feat.params`, and the default dictionary from the first training corpus. ([03b](03-sphinx-asr-mason/index.md#03b-class-config-model))
- **13. Cluster parallelism is untouched.** Templates set `CFG_NPART = DEC_CFG_NPART = 1` with `Queue::POSIX`, so a run uses one core on one node. ([03k](03-sphinx-asr-mason/index.md#03k-deployment-cluster-integration-gap))

**Bugs in Mason's wrapper**

- **14. Per-split LM is broken.** `lm.py` calls an undefined `extract_text()`, so only `sphinx lm switchboard --all` works. ([03h](03-sphinx-asr-mason/index.md#03h-activity-lm))
- **15. `feats.py` needs Python 3.12+.** Its f-string quoting won't parse on Python 3.10 or 3.11. ([03e](03-sphinx-asr-mason/index.md#03e-activity-feats))
- **16. Torque path is missing a file.** `sphinx.sh`'s qsub branch calls `sphinx_job.sh` in the submodule's scripts directory, which doesn't exist. ([03a](03-sphinx-asr-mason/index.md#03a-component-architecture))
- **17. x86 object files are committed.** 24 x86-64 `.o` files are tracked under `vendor/cmu_toolkit/src`, which risks link failures on aarch64. ([03i](03-sphinx-asr-mason/index.md#03i-component-build-vendor-patches))

**Docker and JSON**

- The Docker image existed only from 2026-03-24 to 2026-03-26 (commits `85e1ba6`, `7581fc6`, `57ed2db`, removed in `00dcf68`). It was replaced by the native build plus venv. ([03j](03-sphinx-asr-mason/index.md#03j-deployment-docker-vs-venv))
- No JSON is used anywhere. All configuration is YAML.

## Drift in the older Phase 0 package (`ivaliceCluster/docs/uml/`)

- **01a, 01c:** mention sphinx aarch64 wheels and a `10-sphinx-asr` sub-stage. Neither exists. They also omit `remove_pigen_stage2_export_marker`.
- **02a:** lists `config.py` helpers `_resolve_corpus` and `_expand_splits`, which don't exist. The real helpers are `load_corpus`, `validate_experiment`, `_validate_split`, and `_resolve_lm_path`. It also gives `cmn` as a bool (it's a string such as `live`) and `fillers` as a list (it's a map).
- **02d:** omits the silent-continue behaviour on step failure (finding 11).
- **03a:** names `10.falign_ci_hmm/slave_ci.pl` (it's `slave_convg.pl`) and `slave.state_tying.pl` (it's `slave.state-tying.pl`). It also says step 90 runs only for `.semi.`, but it also runs for `.ptm.`.
- **CLAUDE.md:** references `stage-corpus.sh`, `smoke-sphinx.sh`, `docs/daily-logs/`, and `assets/sphinx-wheels/`. None of these exist yet.
