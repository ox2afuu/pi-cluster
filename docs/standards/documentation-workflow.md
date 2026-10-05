# Documentation workflow

How the wiki is built, what checks run when, and how to add to it.
Everything here is configured in `lefthook.yml`, `mkdocs.yml`,
`pyproject.toml` and the scripts in `tools/docs/`.

## One-time setup

```sh
uv sync --group docs        # MkDocs and plugins, pinned by uv.lock
lefthook install            # writes .git/hooks/pre-commit, post-commit, pre-push
```

Tools the hooks call: `uv`/`uvx`, `npx` (Node), `plantuml` (Java) and
`shellcheck`. Python for the docs tooling is whatever uv selects for
`requires-python = ">=3.12"` (3.12 and 3.14 both build).

## The checks

### pre-commit (parallel, staged files only, never `pi-gen/` or `sphinx-asr/`)

| Job | Runs on | Catches | Run it by hand |
| --- | --- | --- | --- |
| `uml-render` | staged `docs/**/*.puml` | PlantUML syntax errors; then re-renders `.svg` and `.png` and stages them, so renders never lag their source | `plantuml -tsvg docs/uml/<pkg>/<file>.puml` and again with `-tpng` |
| `uml-check` | staged `docs/**/*.puml` | Sources that do not parse (`UM001`, with the line), missing `.svg` (`UM002`) or `.png` (`UM003`) | `uv run --group docs python tools/docs/check_uml.py docs/uml*/*/*.puml` |
| `markdownlint` | staged `*.md` | Markdown structure problems (fences without blank lines, bad list numbering, heading levels) under `.markdownlint-cli2.yaml` | `npx --yes markdownlint-cli2@0.23.3 docs/**/*.md` |
| `doc-paths` | staged `*.md` | Inline code or links naming a repo path (`scripts/`, `stages/`, `configs/`, `docs/`, `assets/`, `tools/`, `sphinx-asr/`, `pi-gen/`) that does not exist (`DP001`) | `uv run --group docs python tools/docs/check_doc_paths.py README.md docs/index.md` |
| `codespell` | staged md, puml, py, sh, yml | Common misspellings; domain words are allowed in `.codespellrc` | `uvx codespell@2.4.3 docs` |
| `no-emoji` | every staged text file | Emoji code points (`EM001`), per the no-emoji house rule | `uv run --group docs python tools/docs/check_no_emoji.py <files>` |
| `shellcheck` | staged `*.sh` | Shell bugs, with `.shellcheckrc` following sourced helpers | `shellcheck scripts/*.sh` |
| `mkdocs-strict` | when anything under `docs/`, `mkdocs.yml`, `tools/docs/`, any `*.md`, `pyproject.toml` or `uv.lock` is staged | Broken links, missing anchors, bad nav entries, mkdocstrings/griffe errors, generator crashes: any MkDocs warning fails | `uv run --group docs python tools/docs/mkdocs_build.py --strict --site-dir .cache/mkdocs-check` |

Notes:

- `uml-render` and `uml-check` run in that order (a piped group inside the
  otherwise parallel hook), so a new diagram's renders exist before they
  are checked.
- `mkdocs-strict` builds the **working tree**, not the index. Unstaged
  edits to docs can make it pass or fail; stash them if in doubt.
- `tools/docs/mkdocs_build.py` is `mkdocs build` with its output filtered
  to warnings and errors. It deliberately does not pass `--quiet`:
  `--quiet` lowers MkDocs logging to errors only, so `--strict` never sees
  the warnings and a broken link would pass.
- The `doc-paths` allowlist is `docs/.planned-paths`: one glob per line for
  paths a page may cite before they exist (planned components) or that are
  created locally (airgap payloads under `assets/`, `pi-gen/deploy`).
  Prefer fixing the reference; add to the allowlist only for genuinely
  planned or generated paths.

### post-commit

| Job | What it does |
| --- | --- |
| `site-build` | Rebuilds the full site into `site/` (gitignored) so `site/index.html` is always current. Not strict. |
| `vault-export` | Runs `tools/docs/export_vault_note.py` (see [below](#vault-export)). |

Both run with `uv run --frozen` so uv never rewrites `uv.lock`, and both
print a warning instead of failing. Neither modifies tracked files.

### pre-push

| Job | What it does |
| --- | --- |
| `mkdocs-strict-full` | The strict build, regardless of what changed |
| `doc-paths-all` | `check_doc_paths.py` over every tracked `*.md` outside the submodules |
| `docs-tests` | `uv run --group docs --with pytest pytest tools/docs/tests -q` |

### CI

`.github/workflows/docs.yml` checks out with submodules and full history
and runs `uv run --group docs mkdocs build --strict` on every push and
pull request. It does not deploy; publishing is a separate decision.

Run everything locally the way the hooks do:

```sh
lefthook run pre-commit --all-files
lefthook run pre-push
```

## How auto-update works

Three kinds of pages, three update paths:

1. **Generated pages** (`api/`, `experiments/`, every UML gallery
   `index.md`) do not exist in git. `mkdocs-gen-files` runs the scripts in
   `tools/docs/` at the start of every build:
    - `tools/docs/gen_api.py` writes one page per module under
      `sphinx-asr/scripts/` with a `::: module` directive; mkdocstrings
      renders the current docstrings with griffe (static, nothing is
      imported).
    - `tools/docs/gen_uml.py` writes a gallery per diagram package from
      the `.puml` titles, the committed `.svg` renders and the sources.
    - `tools/docs/gen_experiments.py` reads the YAML templates, the
      `sphinx-asr` git log and any experiments on disk.

    A submodule bump, a new diagram or a new experiment therefore shows up
    on the next build with no doc edit.

2. **Hand-written pages** are kept honest by the hooks: `doc-paths` fails
   when a cited path disappears, `mkdocs-strict` fails when a link or
   anchor breaks, and the "Drift" admonitions record known disagreements
   between older docs and the code.
3. **Page dates** come from git through
   `mkdocs-git-revision-date-localized-plugin` (creation and last-update
   date at the bottom of each page; build time for uncommitted pages).
   `tools/docs/mkdocs_hooks.py` suppresses one spurious plugin warning for
   pages that have no commit yet, so new pages pass the strict pre-commit
   build.

The post-commit hook then rebuilds `site/` and exports the vault note.

## Adding a diagram

1. Create `docs/uml/<package>/<NNx>-<type>-<name>.puml` (or under
   `docs/uml-verified/`, which uses `!include ../_style.iuml`). Start with
   `@startuml <name>` and a `title` line; the title becomes the gallery
   heading.
2. `git add` the source and commit. `uml-render` renders and stages
   `.svg` and `.png`; `uml-check` confirms all three exist.
3. The gallery for that package picks it up on the next build, anchored at
   `<package>/index.md#<file-stem>`. Link to it from the relevant
   architecture page if it explains a flow.
4. A new package directory needs nothing else: `gen_uml.py` creates its
   gallery and nav entry.

!!! warning "Drift"
    `CONTRIBUTING.md` and `README.md` render with
    `plantuml -tsvg -tpng docs/uml/**/*.puml`. PlantUML 1.2026.8 honours
    only the last `-t` flag, so that command writes PNGs only. Render SVG
    and PNG as two commands, as the hook does.

## Adding a page

1. Write it under the right section of `docs/` and add it to
   `docs/SUMMARY.md` (the nav comes from that file through
   `mkdocs-literate-nav`).
2. Cite code as inline code with the repo-relative path, for example
   `scripts/build.sh` or `sphinx-asr/scripts/lib/config.py`, so
   `doc-paths` can verify it.
3. Where the code and an older document disagree, add a
   `!!! warning "Drift"` admonition naming both sides instead of picking
   one silently.
4. Use no emoji; spell-check terms that codespell rejects by adding them to
   `.codespellrc` with a one-line reason.

## Vault export

`tools/docs/export_vault_note.py` runs after every commit and is a no-op
unless `IVALICE_VAULT_DIR` is set. When it is, it overwrites exactly one
note, `$IVALICE_VAULT_DIR/${IVALICE_VAULT_SUBDIR:-Engineering}/ivaliceCluster Engineering Wiki.md`,
containing:

- frontmatter: `type: reference`, `project`, `source_repo`, `branch`,
  `commit`, `status`, `created` (kept from the previous note), `updated`,
  `updated_at` (timestamp) and `tags`;
- the latest commit and the `sphinx-asr` pointer;
- open review findings per review page (rows whose Status column starts
  with `open` or `in progress`);
- an experiment registry summary;
- the last five settings changelog entries;
- `file://` links to the pages in `site/`.

It writes through a temporary file and a rename, never deletes anything,
and reports failures as warnings. See [Research](../research/index.md) for
why the wiki and the vault are separate.
