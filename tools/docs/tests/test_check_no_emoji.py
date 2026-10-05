"""Tests for check_no_emoji.py."""

import check_no_emoji as cne


def test_emoji_is_reported_with_codepoint(tmp_path, capsys):
    """An emoji in a text file is reported with line, code point and name.

    Given:
        - ``notes.md`` whose line 2 contains U+1F680 ROCKET.
        - Baseline: line 1 holds an arrow and an em dash, which are allowed.
    When:
        ``main`` runs on the file.
    Then:
        - The exit status is 1.
        - One finding is printed, for line 2, naming U+1F680 'ROCKET'.
    """
    path = tmp_path / "notes.md"
    path.write_text("a → b — c\nlaunch \U0001F680\n", encoding="utf-8")

    status = cne.main([str(path)])

    out = capsys.readouterr().out.strip().splitlines()
    assert status == 1
    assert out == [f"{path}:2: EM001 emoji U+1F680 'ROCKET'"]


def test_clean_and_binary_files_pass(tmp_path, capsys):
    """Plain text and binary files produce no findings.

    Given:
        - ``clean.txt`` with ASCII, arrows and box-drawing characters.
        - ``blob.bin`` with a NUL byte followed by emoji-like UTF-8 bytes.
        - Baseline: binary files are skipped, not decoded.
    When:
        ``main`` runs on both files.
    Then:
        - The exit status is 0.
        - Nothing is printed.
    """
    clean = tmp_path / "clean.txt"
    clean.write_text("ok ← ─│ done\n", encoding="utf-8")
    blob = tmp_path / "blob.bin"
    blob.write_bytes(b"\x00\x01" + "\U0001F600".encode())

    status = cne.main([str(clean), str(blob)])

    assert status == 0
    assert capsys.readouterr().out == ""
