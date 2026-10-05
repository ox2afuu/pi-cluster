# 0001: MkDocs Material, mkdocstrings and pre-rendered PlantUML

- **Status:** Accepted
- **Date:** 2026-10-04
- **Deciders:** repository owner

## Context

Engineering knowledge for the cluster was spread across `README.md`,
`CONTRIBUTING.md`, an owner-only `CLAUDE.md`, two sets of PlantUML
diagrams and the code itself, and it had drifted: the README quick start
calls flags that `scripts/personalize-node.sh` does not have, and several
documented components do not exist (see the
[baseline review](../../reviews/2026-10-04-baseline.md)). The thesis needs
one canonical reference that:

- renders Python API documentation from the `sphinx-asr` docstrings,
  which are being converted to Google style;
- shows the existing PlantUML diagrams without a rendering server, since
  the project is airgap-minded and diagrams are already committed as
  `.svg` and `.png`;
- regenerates the parts that can be derived from code (API, settings,
  diagram galleries) on every build;
- is cheap to check in git hooks and CI with one strict build command;
- needs no JavaScript toolchain to build.

## Decision

We will build the wiki with **MkDocs Material** from `docs/`, generate the
API reference with **mkdocstrings** (Python handler, Google style), and
embed the **committed SVG renders** of PlantUML diagrams, re-rendered by a
pre-commit hook with the local `plantuml` binary. Generated pages are
written by `mkdocs-gen-files` scripts in `tools/docs/` at build time and
are never committed. Tooling is pinned through a uv dependency group.

## Alternatives considered

| Option | Why not |
| --- | --- |
| Sphinx with autodoc and napoleon | Mature API docs, but autodoc imports modules, and the `sphinx-asr` scripts are not a package (no `__init__.py` in `sphinx-asr/scripts/` or `sphinx-asr/scripts/lib/`, and `sphinx-asr/scripts/setup.py` is a CLI script). mkdocstrings uses griffe, which reads source statically. reStructuredText also raises the cost of the hand-written pages. |
| Docusaurus | Needs a Node build and React for what is mostly Markdown; no first-class Python API extraction. |
| Kroki (server-side diagram rendering) | Needs a running Kroki service or network access at build time. Pre-rendered SVGs work offline, diff in review, and render on GitHub too. |
| PlantUML MkDocs plugins that render at build time | Every build would need Java and PlantUML (CI included). The hook already renders on commit, so the build only has to embed files. |
| Keep docs as loose Markdown on GitHub | No search, no generated API or settings pages, and nothing fails when a link or path rots. |

## Consequences

- `mkdocs build --strict` is the single gate. Broken links, missing
  anchors and griffe problems fail the pre-commit hook, the pre-push hook
  and CI the same way.
- Diagram renders stay committed, so every `.puml` change must carry its
  `.svg` and `.png`. The `uml-render` and `uml-check` hooks enforce it.
- Contributors need `uv` (and Java plus PlantUML only when editing
  diagrams). `node` is used only to run markdownlint through `npx`.
- The API reference quality tracks the docstring conversion in
  `sphinx-asr`; unconverted docstrings still render as plain text.
- Publishing the site (GitHub Pages or elsewhere) is a separate, later
  decision; CI only builds.
