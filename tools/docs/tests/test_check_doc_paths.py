"""Tests for check_doc_paths.py."""

from pathlib import Path

import check_doc_paths as cdp


def make_repo(tmp_path: Path) -> Path:
    """Create a tiny repo tree with one real script and one doc page."""
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "build.sh").write_text("#!/bin/sh\n")
    (tmp_path / "docs").mkdir()
    return tmp_path


def test_missing_inline_code_path_is_reported(tmp_path, capsys):
    """A cited script that does not exist is reported with file and line.

    Given:
        - A repo containing ``scripts/build.sh`` only.
        - A page whose line 3 cites `scripts/nope.sh` and line 1 cites
          `scripts/build.sh`.
        - Baseline: an existing path produces no finding.
    When:
        ``main`` runs on the page.
    Then:
        - The exit status is 1.
        - Exactly one finding is printed.
        - The finding is ``<page>:3: DP001 missing path 'scripts/nope.sh'``.
    """
    repo = make_repo(tmp_path)
    page = repo / "docs" / "page.md"
    page.write_text("Run `scripts/build.sh`.\n\nThen `scripts/nope.sh`.\n")

    status = cdp.main(["--repo-root", str(repo), str(page)])

    out = capsys.readouterr().out.strip().splitlines()
    assert status == 1
    assert len(out) == 1
    assert out[0] == f"{page}:3: DP001 missing path 'scripts/nope.sh'"


def test_fenced_code_line_suffix_and_braces_are_handled(tmp_path, capsys):
    """Fences are skipped; line suffixes are stripped; braces are expanded.

    Given:
        - A repo with ``scripts/build.sh``.
        - A page citing ``scripts/missing.sh`` only inside a fenced block,
          `scripts/build.sh:12-20` inline, and `scripts/{build,build}.sh`.
        - Baseline: a fully valid page exits 0 and prints nothing.
    When:
        ``main`` runs on the page.
    Then:
        - The exit status is 0.
        - Nothing is printed.
    """
    repo = make_repo(tmp_path)
    page = repo / "docs" / "page.md"
    page.write_text(
        "```sh\nscripts/missing.sh\n`scripts/missing.sh`\n```\n"
        "See `scripts/build.sh:12-20` and `scripts/{build,build}.sh`.\n"
    )

    status = cdp.main(["--repo-root", str(repo), str(page)])

    assert status == 0
    assert capsys.readouterr().out == ""


def test_planned_paths_allowlist_suppresses_findings(tmp_path, capsys):
    """Paths listed in the allowlist (or below an allowlisted dir) pass.

    Given:
        - An allowlist with a comment line and ``stages/future-stage``.
        - A page citing `stages/future-stage/run.sh`, which does not exist.
        - Baseline: without the allowlist this path is reported.
    When:
        ``main`` runs with ``--planned`` pointing at the allowlist.
    Then:
        - The exit status is 0.
        - Nothing is printed.
    """
    repo = make_repo(tmp_path)
    planned = repo / "planned"
    planned.write_text("# future work\nstages/future-stage   # comment\n")
    page = repo / "docs" / "page.md"
    page.write_text("Later: `stages/future-stage/run.sh`.\n")

    status = cdp.main(["--repo-root", str(repo), "--planned", str(planned), str(page)])

    assert status == 0
    assert capsys.readouterr().out == ""


def test_links_resolve_relative_to_file_then_repo_root(tmp_path, capsys):
    """Link targets with a known prefix resolve against the page, then the root.

    Given:
        - ``README.md`` at the repo root linking to ``scripts/build.sh``
          (exists) and ``docs/gone.md`` (does not).
        - Baseline: links to URLs and anchors are never checked.
    When:
        ``main`` runs on ``README.md``.
    Then:
        - The exit status is 1.
        - Only ``docs/gone.md`` is reported.
    """
    repo = make_repo(tmp_path)
    readme = repo / "README.md"
    readme.write_text(
        "[b](scripts/build.sh) [g](docs/gone.md) [u](https://x.test/scripts/a) [a](#top)\n"
    )

    status = cdp.main(["--repo-root", str(repo), str(readme)])

    out = capsys.readouterr().out
    assert status == 1
    assert "docs/gone.md" in out and "scripts/build.sh" not in out
