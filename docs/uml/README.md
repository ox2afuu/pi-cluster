# UML documentation — ivaliceCluster

Design artifacts for the cluster, the sphinx-asr workload that runs on it,
the CMU Sphinx domain the workload is a wrapper over, the proposed Slurm
integration, and the future federation layer.

All sources are text (PlantUML `.puml` + Mermaid inline in markdown) so
diffs are readable. Rendered `.svg` and `.png` are checked in alongside
sources so GitHub and IDE previews work without a local toolchain.

## Packages

| Package | Purpose | Status |
| --- | --- | --- |
| [01-build-lifecycle](01-build-lifecycle/) | How `build.sh` produces `ivalice.img` via pi-gen; current Podman path and stock Docker alternative. Operator-facing. | Phase 0 |
| [02-sphinx-asr-asis](02-sphinx-asr-asis/) | Today's sphinx-asr: class model, per-subcommand sequences, single-node deployment, CLI dispatch component. Baseline before Slurm changes. | Phase 0 |
| [03-cmu-sphinx-domain](03-cmu-sphinx-domain/) | CMU Sphinx domain model independent of our wrapper: acoustic model lifecycle, Baum-Welch EM, decoder pipeline, corpus/dict/LM relationships, end-to-end dataflow. Long-term spec for the eventual Perl-to-Python port. | Phase 0 |
| [04-slurm-integration](04-slurm-integration/) | Proposed Slurm integration: cluster components, train via Queue::Slurm, decode array, full-run activity, post-integration deployment. Reviewed before Phase 1–3 implementation. | Phase 0 |
| [05-federation-future](05-federation-future/) | Two-cluster + arbitrary-node federation design: components, cross-cluster train, artifact flow, interface contracts, node-join. Documented for design review; implementation deferred. | Future work |

## Conventions

- Each package has numeric-prefix filenames (`01a`, `01b`, ...) for ordering.
- One diagram per file.
- Each `.puml` file has a matching `.svg` and `.png` render, built by the
  command below and committed alongside the source.
- Class diagrams use full attribute/method signatures where legible; elide
  noise with `..`.
- Sequence diagrams name the actor (not the file) where possible, so the
  diagram survives refactors.
- No color unless semantically meaningful (e.g. "failure path" red in a
  sequence diagram). Black-and-white is preferred.
- Formal package diagrams use PlantUML. Mermaid is reserved for the
  inline diagrams in `README.md` where GitHub's native render is
  helpful.

## Rendering

Renders are built with [PlantUML](https://plantuml.com/) (Java; requires
graphviz for some diagram types).

Install on macOS: `brew install plantuml` (pulls in graphviz).

Install on Debian/Trixie: `apt install plantuml graphviz default-jre`.

Render a whole package:
```
plantuml -tsvg docs/uml/01-build-lifecycle/*.puml
plantuml -tpng docs/uml/01-build-lifecycle/*.puml
```

Render everything:
```
plantuml -tsvg docs/uml/**/*.puml
plantuml -tpng docs/uml/**/*.puml
```

Regenerate after editing any `.puml` and commit the updated `.svg` + `.png`
in the same change. A pre-commit hook that runs the above and stages the
outputs is a reasonable future addition; not required yet.

## Phase 0 acceptance gate

Before any runtime code change lands (Phase 1+), the following must hold:

- Packages 01–04 have complete `.puml` sources.
- Every `.puml` has a committed `.svg` and `.png` render.
- This README indexes every package with a one-line purpose.
- The root `README.md` cross-references the build-lifecycle and
  Slurm-integration packages from its "Repo layout" and "Status"
  sections.

Package 05 is Phase-0-aware but its implementation is deferred; drafts of
05a–05f are acceptable to land incrementally.
