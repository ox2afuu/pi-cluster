#!/usr/bin/env python3
"""Export a one-note summary of the engineering wiki to an Obsidian vault.

Usage:
    export_vault_note.py [--site-dir DIR]

Opt-in. With ``IVALICE_VAULT_DIR`` unset, prints one skip line and exits 0.
Otherwise overwrites exactly one note:

    $IVALICE_VAULT_DIR/${IVALICE_VAULT_SUBDIR:-Engineering}/ivaliceCluster Engineering Wiki.md

The note follows the vault conventions for a generated reference note:
YAML frontmatter (``type: reference``, project, source repo, branch, commit,
``created``/``updated`` dates, an ``updated_at`` timestamp, tags), plain
portable markdown, ``[[wikilinks]]`` only for vault-internal links and
markdown links for everything else, no HTML, no secrets. The ``created``
date of an existing note is preserved across overwrites.

The body holds the latest commit, open review findings (parsed from the
Status column of ``docs/reviews/*.md``), an experiment registry summary,
the last five settings changelog entries and ``file://`` links into the
built site. Nothing in the repository is modified.

Called by the lefthook post-commit hook; it must never block a commit, so
every failure is reported as a warning and the exit status is still 0.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gen_experiments  # noqa: E402  (sibling module, path set above)

REPO_ROOT = HERE.parents[1]
NOTE_NAME = "ivaliceCluster Engineering Wiki.md"
DEFAULT_SUBDIR = "Engineering"
PROJECT_SLUG = "ivalice-cluster"
OPEN_STATUSES = ("open", "in progress")


def git(*args: str, cwd: Path = REPO_ROOT) -> str:
    """Run a git command and return stripped stdout ('' on failure)."""
    try:
        return subprocess.run(
            ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=False, timeout=30
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def count_open_findings(reviews_dir: Path) -> dict[str, dict[str, int]]:
    """Count review rows by status, per review page.

    Args:
        reviews_dir: ``docs/reviews``. Every ``*.md`` except ``index.md`` is
            scanned for markdown tables whose header has a ``Status`` column.

    Returns:
        Mapping of page stem to ``{"open": n, "total": m}``, where ``open``
        counts rows whose status starts with one of ``OPEN_STATUSES``.
    """
    result: dict[str, dict[str, int]] = {}
    if not reviews_dir.is_dir():
        return result
    for page in sorted(reviews_dir.glob("*.md")):
        if page.name == "index.md":
            continue
        open_n = total = 0
        status_col: int | None = None
        for line in page.read_text(encoding="utf-8").splitlines():
            if not line.lstrip().startswith("|"):
                status_col = None
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if status_col is None:
                lowered = [c.lower() for c in cells]
                status_col = lowered.index("status") if "status" in lowered else -1
                continue
            if status_col < 0 or set(line.replace("|", "").strip()) <= set("-: "):
                continue
            if status_col < len(cells):
                total += 1
                if cells[status_col].lower().startswith(OPEN_STATUSES):
                    open_n += 1
        if total:
            result[page.stem] = {"open": open_n, "total": total}
    return result


def read_created(note: Path) -> str | None:
    """Return the ``created:`` date of an existing note, if any."""
    try:
        text = note.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r"^created:\s*(\d{4}-\d{2}-\d{2})\s*$", text, re.MULTILINE)
    return m.group(1) if m else None


def yaml_str(value: str) -> str:
    """Quote a scalar for YAML frontmatter."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def site_link(site_dir: Path, rel: str, label: str) -> str:
    """Markdown link to a built site page, noting when it is not built."""
    target = site_dir / rel
    suffix = "" if target.exists() else " (not built yet)"
    return f"- [{label}]({target.resolve().as_uri()}){suffix}"


def render_note(now: dt.datetime, created: str | None, site_dir: Path) -> str:
    """Build the full note text."""
    branch = git("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    sha = git("rev-parse", "--short", "HEAD") or "unknown"
    subject = git("log", "-1", "--format=%s") or ""
    author_date = git("log", "-1", "--format=%ad", "--date=short") or ""
    remote = git("config", "--get", "remote.origin.url") or str(REPO_ROOT)
    sphinx_sha = git("rev-parse", "--short", "HEAD", cwd=gen_experiments.SPHINX_DIR) or "not checked out"
    today = now.date().isoformat()

    reviews = count_open_findings(REPO_ROOT / "docs" / "reviews")
    open_total = sum(r["open"] for r in reviews.values())
    all_total = sum(r["total"] for r in reviews.values())

    reg = gen_experiments.collect_registry(gen_experiments.experiments_dir())
    with_results = sum(1 for r in reg.rows if r.results and "error" not in r.results)
    changelog = gen_experiments.collect_changelog(gen_experiments.SPHINX_DIR, limit=5)

    lines = [
        "---",
        "type: reference",
        f"project: {PROJECT_SLUG}",
        f"source_repo: {yaml_str(remote)}",
        f"branch: {yaml_str(branch)}",
        f"commit: {yaml_str(sha)}",
        "status: active",
        f"created: {created or today}",
        f"updated: {today}",
        f"updated_at: {yaml_str(now.isoformat(timespec='seconds'))}",
        "generated_by: tools/docs/export_vault_note.py",
        "tags: [ivalice-cluster, engineering-wiki, generated]",
        "---",
        "",
        "# ivaliceCluster Engineering Wiki",
        "",
        "> [!info] Generated note",
        "> Overwritten after every commit by the ivaliceCluster post-commit hook.",
        "> Edit the wiki in the repository, not this note. Project context:",
        f"> [[projects/{PROJECT_SLUG}/index|{PROJECT_SLUG}]].",
        "",
        "## Latest commit",
        "",
        f"- `{sha}` on `{branch}` ({author_date}): {subject}",
        f"- sphinx-asr submodule at `{sphinx_sha}`",
        "",
        "## Review findings",
        "",
        f"- Open: {open_total} of {all_total}",
    ]
    for name, counts in reviews.items():
        lines.append(f"- {name}: {counts['open']} open of {counts['total']}")
    lines += ["", "## Experiment registry", ""]
    if not reg.exists:
        lines.append("- No experiments directory found (`SPHINX_EXPERIMENTS_DIR` unset or missing).")
    else:
        lines.append(f"- Experiments: {len(reg.rows)} readable, {len(reg.unreadable)} unreadable, {with_results} with results")
        for r in reg.rows[-5:]:
            res = r.results or {}
            wer = res.get("wer", "-") if "error" not in res else "-"
            lines.append(f"- `{r.exp_id}`: train {', '.join(r.train)}; decode {r.decode}; WER {wer}")
    lines += ["", "## Settings changelog (last 5)", ""]
    if changelog is None:
        lines.append("- sphinx-asr git history unavailable.")
    elif not changelog:
        lines.append("- No settings commits.")
    else:
        for c in changelog:
            noun = "file" if len(c.files) == 1 else "files"
            lines.append(f"- `{c.sha}` {c.date} {c.subject} ({len(c.files)} {noun})")
    lines += [
        "",
        "## Wiki pages (local build)",
        "",
        site_link(site_dir, "index.html", "Home"),
        site_link(site_dir, "reviews/index.html", "Reviews"),
        site_link(site_dir, "experiments/registry/index.html", "Experiment registry"),
        site_link(site_dir, "experiments/changelog/index.html", "Settings changelog"),
        site_link(site_dir, "experiments/settings/index.html", "Settings reference"),
        site_link(site_dir, "api/index.html", "API reference"),
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Always returns 0 (post-commit must not block)."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site-dir", type=Path, default=REPO_ROOT / "site")
    args = parser.parse_args(argv)

    vault = os.environ.get("IVALICE_VAULT_DIR", "").strip()
    if not vault:
        print("export_vault_note: IVALICE_VAULT_DIR not set; skipping vault export")
        return 0
    try:
        vault_dir = Path(vault).expanduser()
        if not vault_dir.is_dir():
            print(f"export_vault_note: WARNING vault dir {vault_dir} does not exist; skipping")
            return 0
        subdir = os.environ.get("IVALICE_VAULT_SUBDIR", "").strip() or DEFAULT_SUBDIR
        note = vault_dir / subdir / NOTE_NAME
        note.parent.mkdir(parents=True, exist_ok=True)
        now = dt.datetime.now().astimezone()
        text = render_note(now, read_created(note), args.site_dir)
        tmp = note.with_name(note.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(note)
        print(f"export_vault_note: wrote {note}")
    except Exception as exc:  # noqa: BLE001 - never block a commit
        print(f"export_vault_note: WARNING export failed: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
