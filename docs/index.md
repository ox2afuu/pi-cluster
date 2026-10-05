# ivaliceCluster engineering wiki

ivaliceCluster builds a six-node Raspberry Pi CM4 research cluster (DeskPi
Super6c carrier, Debian 13 Trixie arm64, Slurm and munge, optional k3s,
airgapped on `10.42.0.0/24`) from one unified pi-gen image, then converges
it with Ansible. The cluster exists to run CMU Sphinx acoustic-model
training and decoding for a thesis; that workload is the `sphinx-asr`
submodule.

This wiki is the canonical engineering reference for both. It is built
with MkDocs Material from `docs/` in this repository and it is checked on
every commit, so a page that cites a path or a diagram is a page that
still matches the code.

## How the wiki is organised

| Section | What it holds | Written by |
| --- | --- | --- |
| [Architecture](architecture/index.md) | Topology, image build, provisioning, the ASR workload on the cluster | hand, against the code |
| [UML: Phase 0 design](uml/README.md) | The original design packages (build lifecycle, sphinx-asr as-is, CMU Sphinx domain, proposed Slurm integration, federation) | hand-drawn PlantUML, galleries generated |
| [UML: code-verified](uml-verified/README.md) | The newer diagram set checked line by line against the code, with findings | hand-drawn PlantUML, galleries generated |
| [Experiments](experiments/index.md) | Settings reference, settings changelog, experiment registry | generated on every build |
| [API reference](api/index.md) | One page per `sphinx-asr/scripts` module, from docstrings | generated on every build |
| [Standards](standards/docstrings.md) | Docstring rules, the documentation workflow, architecture decision records | hand |
| [Reviews](reviews/index.md) | Dated code reviews with a status per finding | hand |
| [Research](research/index.md) | How this wiki connects to the Obsidian research vault | hand |

## How it keeps itself current

- **Generated pages are rebuilt from the code every time.** The scripts in
  `tools/docs/` run inside the MkDocs build (through `mkdocs-gen-files`).
  They read the `sphinx-asr` submodule, its git history and the PlantUML
  sources, so the API reference, diagram galleries and experiment pages
  never go stale and are never committed.
- **Git hooks keep the hand-written pages honest.** `lefthook.yml` runs
  link, path, spelling, emoji, diagram and strict-build checks before each
  commit, rebuilds the local site after each commit, and runs the full
  suite before each push. See
  [Documentation workflow](standards/documentation-workflow.md).
- **CI repeats the strict build** on every push and pull request
  (`.github/workflows/docs.yml`).
- **Drift is written down, not guessed away.** Where the older docs and the
  code disagree, pages say so in a "Drift" warning that names both sides.

## Building it locally

```sh
uv run --group docs mkdocs serve          # live preview on 127.0.0.1:8000
uv run --group docs mkdocs build --strict # what CI and the hooks run
```

The post-commit hook also leaves a fresh build in `site/` (gitignored), so
`site/index.html` can be opened directly.
