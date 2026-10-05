"""Generate a gallery page for every PlantUML diagram package.

Run by mkdocs-gen-files on every build. For each package directory (a
directory holding ``.puml`` files) under ``docs/uml/`` and
``docs/uml-verified/`` this writes ``<package>/index.md`` into the build
with, per diagram:

* a heading taken from the ``title`` line of the source (or the file name),
  with an explicit anchor equal to the file stem so other pages can link to
  ``<package>/index.md#<stem>``;
* the committed ``.svg`` render, embedded and zoomable through glightbox;
* a collapsed ``??? note "PlantUML source"`` block with the source.

Hand-written ``index.md`` files win: if a package already has one, the
package is skipped here and the hand-written page must list its diagrams.
Nothing generated here is committed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS_DIR = REPO_ROOT / "docs"
UML_ROOTS = ("uml", "uml-verified")

TITLE_RE = re.compile(r"^\s*title\s+(.+?)\s*$", re.IGNORECASE)


@dataclass(frozen=True)
class Diagram:
    """One PlantUML source and its render.

    Attributes:
        stem: File name without extension, used as the anchor id.
        title: Human title from the ``title`` line, or the stem.
        source: Full text of the ``.puml`` file.
        has_svg: Whether the sibling ``.svg`` render exists.
        has_png: Whether the sibling ``.png`` render exists.
    """

    stem: str
    title: str
    source: str
    has_svg: bool
    has_png: bool


def diagram_title(source: str, fallback: str) -> str:
    """Return the ``title`` of a PlantUML source.

    Args:
        source: PlantUML text.
        fallback: Value returned when no ``title`` line exists.

    Returns:
        The title text, or ``fallback``.
    """
    for line in source.splitlines():
        m = TITLE_RE.match(line)
        if m:
            return m.group(1).strip()
    return fallback


def load_diagram(path: Path) -> Diagram:
    """Read one ``.puml`` file into a :class:`Diagram`."""
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        source = f"' could not read {path.name}: {exc}"
    return Diagram(
        stem=path.stem,
        title=diagram_title(source, path.stem),
        source=source,
        has_svg=path.with_suffix(".svg").is_file(),
        has_png=path.with_suffix(".png").is_file(),
    )


def package_dirs(root: Path) -> list[Path]:
    """Return every directory under ``root`` that directly holds ``.puml`` files."""
    if not root.is_dir():
        return []
    dirs = {p.parent for p in root.rglob("*.puml")}
    return sorted(dirs)


def md_escape(text: str) -> str:
    """Escape text so it renders literally inside a heading or table cell."""
    out = text.replace("\\", "\\\\")
    for ch in "*_[]`|":
        out = out.replace(ch, "\\" + ch)
    return out.replace("<", "&lt;").replace(">", "&gt;")


def humanize(name: str) -> str:
    """Turn ``01-build-lifecycle`` into ``01 Build lifecycle``."""
    head, _, tail = name.partition("-")
    if head.isdigit() and tail:
        return f"{head} {tail.replace('-', ' ').capitalize()}"
    return name.replace("-", " ").capitalize()


def gallery_page(package_rel: str, diagrams: list[Diagram], extra_pages: list[str]) -> str:
    """Render the gallery markdown for one package.

    Args:
        package_rel: Package path relative to ``docs/`` (for the intro line).
        diagrams: Diagrams in display order.
        extra_pages: Hand-written markdown pages in the same directory.

    Returns:
        The page markdown.
    """
    name = package_rel.rsplit("/", 1)[-1]
    lines = [
        f"# {humanize(name)}",
        "",
        f"Generated gallery for `docs/{package_rel}/` ({len(diagrams)} diagrams).",
        "Click a diagram to zoom. Each source is under its render; edit the",
        "`.puml`, and the pre-commit hook re-renders the `.svg` and `.png`.",
        "",
    ]
    if extra_pages:
        lines.append("Other pages in this package:")
        lines.append("")
        for page in extra_pages:
            lines.append(f"- [{Path(page).stem}]({page})")
        lines.append("")
    lines += ["| Diagram | Title |", "| --- | --- |"]
    for d in diagrams:
        lines.append(f"| [`{d.stem}`](#{d.stem}) | {md_escape(d.title)} |")
    lines.append("")
    for d in diagrams:
        lines.append(f"## {md_escape(d.title)} {{#{d.stem}}}")
        lines.append("")
        lines.append(f"`{d.stem}.puml`")
        lines.append("")
        if d.has_svg:
            alt = md_escape(d.title)
            lines.append(f"![{alt}]({d.stem}.svg){{ loading=lazy }}")
        else:
            lines.append('!!! failure "Missing render"')
            lines.append("")
            lines.append(f"    `{d.stem}.svg` is not committed. Run `plantuml -tsvg -tpng {d.stem}.puml`.")
        lines.append("")
        lines.append('??? note "PlantUML source"')
        lines.append("")
        lines.append("    ```text")
        for src_line in d.source.rstrip("\n").splitlines():
            lines.append(f"    {src_line}" if src_line else "")
        lines.append("    ```")
        lines.append("")
    return "\n".join(lines)


def build_pages(docs_dir: Path) -> dict[str, str]:
    """Compute every gallery page.

    Args:
        docs_dir: The MkDocs ``docs/`` directory.

    Returns:
        Mapping of docs-relative output path to page markdown. Packages
        with a hand-written ``index.md`` are left out.
    """
    pages: dict[str, str] = {}
    for root_name in UML_ROOTS:
        for pkg in package_dirs(docs_dir / root_name):
            if (pkg / "index.md").exists():
                continue
            rel = pkg.relative_to(docs_dir).as_posix()
            diagrams = [load_diagram(p) for p in sorted(pkg.glob("*.puml"))]
            extra = sorted(p.name for p in pkg.glob("*.md") if p.name not in {"index.md", "README.md"})
            pages[f"{rel}/index.md"] = gallery_page(rel, diagrams, extra)
    return pages


def summary_nav(docs_dir: Path, root_name: str) -> str:
    """Render the literate-nav ``SUMMARY.md`` for one UML root."""
    lines = ["- [Overview](README.md)"]
    for pkg in package_dirs(docs_dir / root_name):
        rel = pkg.relative_to(docs_dir / root_name).as_posix()
        lines.append(f"- [{humanize(pkg.name)}]({rel}/index.md)")
        for extra in sorted(pkg.glob("*.md")):
            if extra.name in {"index.md", "README.md"}:
                continue
            lines.append(f"    - [{extra.stem}]({rel}/{extra.name})")
    return "\n".join(lines) + "\n"


def main() -> None:
    """Write gallery pages and nav files into the gen-files virtual tree."""
    import mkdocs_gen_files

    for rel, text in build_pages(DOCS_DIR).items():
        with mkdocs_gen_files.open(rel, "w") as fh:
            fh.write(text)
    for root_name in UML_ROOTS:
        if (DOCS_DIR / root_name).is_dir():
            with mkdocs_gen_files.open(f"{root_name}/SUMMARY.md", "w") as fh:
                fh.write(summary_nav(DOCS_DIR, root_name))


if __name__ in {"__main__", "<run_path>"}:
    main()
