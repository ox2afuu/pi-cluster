"""Generate one API reference page per sphinx-asr Python module.

Run by mkdocs-gen-files on every build (see ``mkdocs.yml``). Nothing this
script produces is committed: the pages exist only inside the build.

``sphinx-asr/scripts`` is not an installable package. The scripts import
each other as top-level modules (``from lib.config import ...``,
``from corpus import get_adapter``), and ``scripts/lib`` has no
``__init__.py``. mkdocstrings is therefore configured with two search paths,
``sphinx-asr/scripts`` and ``sphinx-asr/scripts/lib``, and this script maps
each file to the identifier griffe can resolve under those paths:

* ``scripts/train.py``               -> ``train``
* ``scripts/lib/config.py``          -> ``config``
* ``scripts/corpus/__init__.py``     -> ``corpus`` (a real package)
* ``scripts/corpus/librispeech.py``  -> ``corpus.librispeech``
"""

from __future__ import annotations

import ast
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "sphinx-asr" / "scripts"
LIB_DIR_NAME = "lib"
API_DIR = "api"


@dataclass(frozen=True)
class ApiModule:
    """One Python module that gets an API page.

    Attributes:
        identifier: Dotted name griffe resolves under the configured paths.
        source: Path of the module file relative to the repository root.
        summary: First line of the module docstring, or an empty string.
    """

    identifier: str
    source: str
    summary: str


def module_identifier(path: Path, scripts_dir: Path) -> str:
    """Map a ``.py`` file under ``scripts_dir`` to a griffe identifier.

    Args:
        path: Absolute path of a Python file below ``scripts_dir``.
        scripts_dir: The ``sphinx-asr/scripts`` directory.

    Returns:
        The dotted module identifier, for example ``corpus.librispeech``.
    """
    rel = path.relative_to(scripts_dir)
    parts = list(rel.with_suffix("").parts)
    if parts and parts[0] == LIB_DIR_NAME:
        # scripts/lib is on the griffe search path itself.
        parts = parts[1:]
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts)


def first_docstring_line(path: Path) -> str:
    """Return the first non-empty line of a module docstring.

    Args:
        path: Python source file.

    Returns:
        The first docstring line, or an empty string when the file has no
        docstring or cannot be parsed.
    """
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeDecodeError, ValueError):
        return ""
    doc = ast.get_docstring(tree) or ""
    for line in doc.splitlines():
        if line.strip():
            return line.strip()
    return ""


def discover_modules(scripts_dir: Path, repo_root: Path) -> list[ApiModule]:
    """Find every documentable module under ``scripts_dir``.

    Args:
        scripts_dir: The ``sphinx-asr/scripts`` directory (may be missing).
        repo_root: Repository root, used to render relative source paths.

    Returns:
        Modules sorted by identifier. Empty if the directory is missing or
        holds no Python files (for example an uninitialised submodule).
    """
    if not scripts_dir.is_dir():
        return []
    modules: list[ApiModule] = []
    for path in sorted(scripts_dir.rglob("*.py")):
        if "__pycache__" in path.parts or any(p.startswith(".") for p in path.relative_to(scripts_dir).parts):
            continue
        ident = module_identifier(path, scripts_dir)
        if not ident:
            continue
        modules.append(
            ApiModule(
                identifier=ident,
                source=path.relative_to(repo_root).as_posix(),
                summary=first_docstring_line(path),
            )
        )
    return sorted(modules, key=lambda m: m.identifier)


def module_page(module: ApiModule) -> str:
    """Render the markdown page for one module."""
    return (
        f"# `{module.identifier}`\n\n"
        f"Source: `{module.source}`\n\n"
        f"::: {module.identifier}\n"
    )


def index_page(modules: list[ApiModule]) -> str:
    """Render the API landing page."""
    lines = [
        "# API reference",
        "",
        "Generated at build time by `tools/docs/gen_api.py` from the docstrings in",
        "`sphinx-asr/scripts/`. Docstrings follow the Google style described in",
        "[Docstring standards](../standards/docstrings.md); modules that have not",
        "been converted yet still render, just with less structure.",
        "",
    ]
    if not modules:
        lines += [
            '!!! warning "sphinx-asr submodule is empty"',
            "",
            "    No Python modules were found under `sphinx-asr/scripts/`. The",
            "    submodule is probably not checked out. Run:",
            "",
            "    ```sh",
            "    git submodule update --init",
            "    ```",
            "",
            "    and rebuild the site.",
            "",
        ]
        return "\n".join(lines)
    lines += ["| Module | Source | Summary |", "| --- | --- | --- |"]
    for m in modules:
        page = f"{m.identifier.replace('.', '/')}.md"
        summary = m.summary.replace("|", "\\|") or "(no module docstring)"
        lines.append(f"| [`{m.identifier}`]({page}) | `{m.source}` | {summary} |")
    lines.append("")
    return "\n".join(lines)


def summary_nav(modules: list[ApiModule]) -> str:
    """Render the literate-nav ``SUMMARY.md`` for the API section."""
    lines = ["- [Overview](index.md)"]
    for m in modules:
        lines.append(f"- [{m.identifier}]({m.identifier.replace('.', '/')}.md)")
    return "\n".join(lines) + "\n"


def main() -> None:
    """Write the API pages into the mkdocs-gen-files virtual file system."""
    import mkdocs_gen_files

    modules = discover_modules(SCRIPTS_DIR, REPO_ROOT)
    with mkdocs_gen_files.open(f"{API_DIR}/index.md", "w") as fh:
        fh.write(index_page(modules))
    for m in modules:
        rel = f"{API_DIR}/{m.identifier.replace('.', '/')}.md"
        with mkdocs_gen_files.open(rel, "w") as fh:
            fh.write(module_page(m))
    with mkdocs_gen_files.open(f"{API_DIR}/SUMMARY.md", "w") as fh:
        fh.write(summary_nav(modules))


if __name__ in {"__main__", "<run_path>"}:
    main()
