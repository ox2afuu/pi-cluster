#!/usr/bin/env python3
"""Run ``mkdocs build`` for the git hooks with readable, filtered output.

Usage:
    mkdocs_build.py [--verbose] [MKDOCS BUILD ARGS ...]

Why not ``mkdocs build --strict --quiet``: ``--quiet`` raises the MkDocs
log level to ERROR, so WARNING records never reach the counter that
``--strict`` relies on and a broken link would pass. This wrapper runs the
build at normal verbosity, prints only ``WARNING``/``ERROR`` lines and the
final "Aborted" line (everything with ``--verbose``), silences the
MkDocs 2.0 notices printed by Material and properdocs, and exits with
MkDocs' own status.

Example:
    uv run --group docs python tools/docs/mkdocs_build.py --strict --site-dir .cache/mkdocs-check
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

KEEP_RE = re.compile(r"^(?:\x1b\[[0-9;]*m)*(WARNING|ERROR)\b|Aborted|Error:")


def main(argv: list[str] | None = None) -> int:
    """Run the build and return its exit status."""
    args = list(sys.argv[1:] if argv is None else argv)
    verbose = "--verbose" in args
    args = [a for a in args if a != "--verbose"]
    env = dict(os.environ, NO_MKDOCS_2_WARNING="true", DISABLE_MKDOCS_2_WARNING="true")
    proc = subprocess.run(
        [sys.executable, "-m", "mkdocs", "build", *args],
        capture_output=True, text=True, env=env, check=False,
    )
    for line in (proc.stderr + proc.stdout).splitlines():
        if verbose or KEEP_RE.search(line):
            print(line)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
