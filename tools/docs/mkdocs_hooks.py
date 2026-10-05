"""MkDocs hooks for the engineering wiki (registered under ``hooks:`` in mkdocs.yml).

1. ``on_files``: the generators write literate-nav ``SUMMARY.md`` files into
   ``api/``, ``experiments/``, ``uml/`` and ``uml-verified/``. They are nav
   sources, not pages, so they are excluded from the built site (the root
   ``docs/SUMMARY.md`` is excluded through ``exclude_docs``, which does not
   see generated files).

2. Log filter: mkdocs-git-revision-date-localized falls back to the build time for pages
that have no commit yet. With ``enable_creation_date: true`` it then calls
``time.time()`` twice (last revision, then creation) and, when the second
call lands in a later second, warns "First revision timestamp is older
than last revision timestamp". Under ``--strict`` that spurious warning
fails the build for every new, not yet committed page, which is exactly
the state the pre-commit hook builds in.

The filter drops that one message, and only for pages with no git history.
A page that does have history and still triggers it keeps the warning.
"""

from __future__ import annotations

import logging
import re
import subprocess
from functools import lru_cache
from pathlib import Path

from mkdocs.plugins import event_priority
from mkdocs.structure.files import Files, InclusionLevel

REPO_ROOT = Path(__file__).resolve().parents[2]
LOGGER_NAME = "mkdocs.plugins.mkdocs_git_revision_date_localized_plugin.plugin"
MESSAGE_RE = re.compile(r"First revision timestamp is older than last revision timestamp for page (?P<page>.+?)\. ")


@lru_cache(maxsize=None)
def has_history(docs_rel_path: str) -> bool:
    """Return whether ``docs/<docs_rel_path>`` has at least one commit."""
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "log", "-n1", "--format=%H", "--", f"docs/{docs_rel_path}"],
            capture_output=True, text=True, timeout=30, check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return bool(out.strip())


class UncommittedPageFilter(logging.Filter):
    """Drop the creation-date warning for pages without git history."""

    def filter(self, record: logging.LogRecord) -> bool:
        m = MESSAGE_RE.search(record.getMessage())
        if not m:
            return True
        return has_history(m.group("page"))


def on_startup(command: str, dirty: bool) -> None:  # noqa: ARG001 - MkDocs hook signature
    """Install the log filter once per MkDocs process."""
    logger = logging.getLogger(LOGGER_NAME)
    if not any(isinstance(f, UncommittedPageFilter) for f in logger.filters):
        logger.addFilter(UncommittedPageFilter())


@event_priority(-100)  # after mkdocs-gen-files has added its files
def on_files(files: Files, config) -> Files:  # noqa: ANN001, ARG001 - MkDocs hook signature
    """Exclude every literate-nav ``SUMMARY.md`` from the rendered site."""
    for f in files:
        if f.src_uri == "SUMMARY.md" or f.src_uri.endswith("/SUMMARY.md"):
            f.inclusion = InclusionLevel.EXCLUDED
    return files
