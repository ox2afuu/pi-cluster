#!/usr/bin/env python3
"""Validate PlantUML sources and require their committed renders.

Usage:
    check_uml.py [--plantuml CMD] FILE.puml [FILE.puml ...]

For every ``.puml`` given:

* ``UM001``: the source does not parse (``plantuml -checkonly``). The
  line comes from PlantUML's "Error line N" message when available.
* ``UM002``: the sibling ``.svg`` render is missing.
* ``UM003``: the sibling ``.png`` render is missing.

All files are checked in one PlantUML run; only when that run fails is
each file re-checked on its own, in parallel (``-checkonly`` first, then a
render into a throw-away directory for the failing ones to get the line).
Duplicate arguments are checked once. ``--plantuml`` or the ``PLANTUML``
environment variable overrides the executable (default ``plantuml``).

Output: ``path:line: CODE message``. Exit status is 1 when anything is
reported, 0 otherwise.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ERROR_LINE_RE = re.compile(r"Error line (\d+) in file")


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a command, capturing output; a missing executable becomes rc 127."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=600)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def locate_error(plantuml: list[str], path: Path) -> tuple[bool, int, str]:
    """Check one file alone.

    Returns:
        ``(ok, line, message)``; ``line`` is 1 when PlantUML gives none.
    """
    if run([*plantuml, "-checkonly", str(path)]).returncode == 0:
        return True, 0, ""
    with tempfile.TemporaryDirectory() as tmp:
        proc = run([*plantuml, "-tsvg", "-o", tmp, str(path)])
    if proc.returncode == 0:
        return True, 0, ""
    text = (proc.stdout + proc.stderr).strip()
    m = ERROR_LINE_RE.search(text)
    line = int(m.group(1)) if m else 1
    first = text.splitlines()[0] if text else f"plantuml exited {proc.returncode}"
    return False, line, first


def check(files: list[Path], plantuml: list[str]) -> list[str]:
    """Return every finding for ``files``."""
    findings: list[str] = []
    pumls = list(dict.fromkeys(f for f in files if f.suffix == ".puml"))
    for f in pumls:
        if not f.is_file():
            findings.append(f"{f}:1: UM004 file not found")
    pumls = [f for f in pumls if f.is_file()]
    if pumls:
        proc = run([*plantuml, "-checkonly", *map(str, pumls)])
        if proc.returncode == 127:
            findings.append(f"{pumls[0]}:1: UM005 plantuml not runnable: {proc.stderr.strip()}")
        elif proc.returncode != 0:
            workers = min(len(pumls), os.cpu_count() or 4)
            with ThreadPoolExecutor(max_workers=workers) as pool:
                results = list(pool.map(lambda f: locate_error(plantuml, f), pumls))
            for f, (ok, line, msg) in zip(pumls, results):
                if not ok:
                    findings.append(f"{f}:{line}: UM001 PlantUML syntax error: {msg}")
    for f in pumls:
        if not f.with_suffix(".svg").is_file():
            findings.append(f"{f}:1: UM002 missing render {f.with_suffix('.svg').name}")
        if not f.with_suffix(".png").is_file():
            findings.append(f"{f}:1: UM003 missing render {f.with_suffix('.png').name}")
    return findings


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("--plantuml", default=os.environ.get("PLANTUML", "plantuml"))
    args = parser.parse_args(argv)
    findings = check(args.files, shlex.split(args.plantuml))
    for f in findings:
        print(f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
