"""Tests for export_vault_note.py. Only ever writes into pytest temp dirs."""

from pathlib import Path

import export_vault_note as evn


def test_skips_when_vault_env_is_unset(monkeypatch, capsys, tmp_path):
    """Without IVALICE_VAULT_DIR the export is a no-op.

    Given:
        - ``IVALICE_VAULT_DIR`` unset.
        - Baseline: the temp directory is empty.
    When:
        ``main`` runs.
    Then:
        - The exit status is 0.
        - One skip line is printed.
        - The temp directory is still empty.
    """
    monkeypatch.delenv("IVALICE_VAULT_DIR", raising=False)

    status = evn.main(["--site-dir", str(tmp_path / "site")])

    out = capsys.readouterr().out.strip().splitlines()
    assert status == 0
    assert len(out) == 1 and "skipping" in out[0]
    assert list(tmp_path.iterdir()) == []


def test_writes_one_note_and_preserves_created(monkeypatch, tmp_path):
    """With a vault dir set, exactly one note is (over)written in the subdir.

    Given:
        - A temp vault with ``Notes/ivaliceCluster Engineering Wiki.md``
          whose frontmatter says ``created: 2020-01-02``.
        - ``IVALICE_VAULT_SUBDIR=Notes``.
        - Baseline: no other file exists in the vault.
    When:
        ``main`` runs.
    Then:
        - The exit status is 0.
        - The vault still contains exactly that one file.
        - Its frontmatter keeps ``created: 2020-01-02`` and has
          ``type: reference``, ``commit:`` and ``tags:``.
        - The body has the review, registry and changelog sections.
    """
    vault = tmp_path / "vault"
    note = vault / "Notes" / evn.NOTE_NAME
    note.parent.mkdir(parents=True)
    note.write_text("---\ncreated: 2020-01-02\n---\nold\n")
    monkeypatch.setenv("IVALICE_VAULT_DIR", str(vault))
    monkeypatch.setenv("IVALICE_VAULT_SUBDIR", "Notes")

    status = evn.main(["--site-dir", str(tmp_path / "site")])

    files = [p for p in vault.rglob("*") if p.is_file()]
    text = note.read_text()
    assert status == 0
    assert files == [note]
    assert "created: 2020-01-02" in text and "type: reference" in text
    assert "\ncommit: " in text and "\ntags: [" in text
    assert "## Review findings" in text and "## Experiment registry" in text
    assert "## Settings changelog (last 5)" in text


def test_counts_open_review_rows(tmp_path):
    """Rows are counted per page by their Status column.

    Given:
        - A review page with a 3-row table: open, fixed (abc), in progress.
        - An ``index.md`` with a Status table, which must be ignored.
        - Baseline: tables without a Status column are not counted.
    When:
        ``count_open_findings`` scans the directory.
    Then:
        - Only the review page is counted, with 2 open of 3.
    """
    (tmp_path / "2026-01-01-x.md").write_text(
        "| ID | Status |\n| --- | --- |\n| A | open |\n| B | fixed (abc) |\n| C | in progress |\n"
    )
    (tmp_path / "index.md").write_text("| Value | Status |\n| --- | --- |\n| a | open |\n")

    counts = evn.count_open_findings(Path(tmp_path))

    assert counts == {"2026-01-01-x": {"open": 2, "total": 3}}
