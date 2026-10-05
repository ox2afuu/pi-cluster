#!/usr/bin/env python3
"""Fail when markdown cites a repository path that does not exist.

Usage:
    check_doc_paths.py [--repo-root DIR] [--planned FILE] FILE.md [FILE.md ...]

Scans inline code spans and link targets. A span or link is treated as a
repo-relative path when it starts with one of ``PREFIXES`` (``scripts/``,
``stages/``, ``configs/``, ``docs/``, ``assets/``, ``tools/``,
``sphinx-asr/``, ``pi-gen/``) and contains no whitespace. Fenced code
blocks are skipped. A trailing ``:LINE`` or ``:LINE-LINE,LINE`` suffix is
ignored, ``{a,b}`` braces are expanded, and globs (``*``, ``?``, ``[``)
must match at least one path. Spans containing placeholders (``<``,
``$``, ``...``) are ignored.

Link targets are resolved relative to the markdown file first and then to
the repository root, so ``[x](docs/uml/)`` in ``README.md`` and
``[x](../uml/README.md)`` in a docs page both work.

Paths that do not exist yet on purpose are listed, one glob per line, in
``docs/.planned-paths`` (``#`` starts a comment).

Output: ``path:line: DP001 missing path 'scripts/nope.sh'``. Exit status is
1 when anything is reported, 0 otherwise.
"""

from __future__ import annotations

import argparse
import fnmatch
import glob
import re
import sys
from dataclasses import dataclass
from pathlib import Path

PREFIXES = ("scripts/", "stages/", "configs/", "docs/", "assets/", "tools/", "sphinx-asr/", "pi-gen/")
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
LINK_RE = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
LINE_SUFFIX_RE = re.compile(r":\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$")
BRACE_RE = re.compile(r"\{([^{}]*,[^{}]*)\}")
PLACEHOLDER_CHARS = ("<", ">", "$", "...", "NNN")
GLOB_CHARS = ("*", "?", "[")


@dataclass(frozen=True)
class Finding:
    """One reported problem."""

    path: str
    line: int
    code: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.code} {self.message}"


def load_planned(path: Path) -> list[str]:
    """Read the planned-paths allowlist.

    Args:
        path: The allowlist file. A missing file means an empty allowlist.

    Returns:
        Glob patterns, without comments or blank lines.
    """
    if not path.is_file():
        return []
    patterns = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            patterns.append(line.rstrip("/"))
    return patterns


def expand_braces(text: str) -> list[str]:
    """Expand shell-style ``{a,b}`` alternatives (non-nested)."""
    m = BRACE_RE.search(text)
    if not m:
        return [text]
    out = []
    for alt in m.group(1).split(","):
        out.extend(expand_braces(text[: m.start()] + alt + text[m.end() :]))
    return out


def normalise(candidate: str) -> str | None:
    """Turn a span or link into a checkable path, or ``None`` to skip it."""
    text = candidate.strip()
    if not text or any(ch.isspace() for ch in text):
        return None
    if any(p in text for p in PLACEHOLDER_CHARS):
        return None
    text = text.split("#", 1)[0].split("?", 1)[0] if "://" not in text else text
    text = LINE_SUFFIX_RE.sub("", text)
    text = text.rstrip(".,;:)")
    return text or None


def is_planned(path: str, planned: list[str]) -> bool:
    """Return whether ``path`` (or a parent of it) matches the allowlist."""
    clean = path.rstrip("/")
    parts = clean.split("/")
    for i in range(len(parts), 0, -1):
        prefix = "/".join(parts[:i])
        if any(fnmatch.fnmatchcase(prefix, pat) for pat in planned):
            return True
    return False


def exists(path: str, bases: list[Path]) -> bool:
    """Return whether ``path`` exists (or its glob matches) under any base."""
    for variant in expand_braces(path):
        for base in bases:
            target = base / variant
            if any(ch in variant for ch in GLOB_CHARS):
                if glob.glob(str(target), recursive=True):
                    return True
            elif target.exists():
                return True
    return False


def iter_candidates(text: str):
    """Yield ``(line_number, kind, candidate)`` outside fenced code blocks."""
    fence: str | None = None
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)
            if fence is None:
                fence = marker[0] * 3
            elif marker.startswith(fence):
                fence = None
            continue
        if fence is not None:
            continue
        for cm in INLINE_CODE_RE.finditer(line):
            yield lineno, "code", cm.group(2)
        stripped = INLINE_CODE_RE.sub("", line)
        for lm in LINK_RE.finditer(stripped):
            yield lineno, "link", lm.group(1)


def check_file(md_path: Path, repo_root: Path, planned: list[str]) -> list[Finding]:
    """Check one markdown file.

    Args:
        md_path: Markdown file to scan.
        repo_root: Repository root that repo-relative paths resolve against.
        planned: Allowlisted glob patterns.

    Returns:
        Every missing path, in file order.
    """
    try:
        text = md_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return [Finding(str(md_path), 1, "DP002", f"cannot read file: {exc}")]
    findings = []
    for lineno, kind, raw in iter_candidates(text):
        if kind == "link" and ("://" in raw or raw.startswith(("#", "mailto:"))):
            continue
        path = normalise(raw)
        if path is None or not path.startswith(PREFIXES):
            continue
        bases = [md_path.parent, repo_root] if kind == "link" else [repo_root]
        if exists(path, bases) or is_planned(path, planned):
            continue
        findings.append(Finding(str(md_path), lineno, "DP001", f"missing path '{path}'"))
    return findings


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", type=Path, help="markdown files to check")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--planned", type=Path, default=None, help="allowlist (default: docs/.planned-paths)")
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    planned = load_planned(args.planned or repo_root / "docs" / ".planned-paths")
    findings: list[Finding] = []
    for f in args.files:
        if f.suffix.lower() not in {".md", ".markdown"}:
            continue
        findings.extend(check_file(f, repo_root, planned))
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
