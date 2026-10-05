"""Tests for check_uml.py, using a fake ``plantuml`` so no JVM is needed."""

import stat
from pathlib import Path

import check_uml

FAKE_PLANTUML = """#!/bin/sh
# Fake plantuml: any argument file containing BROKEN fails at line 3.
rc=0
for a in "$@"; do
  case "$a" in
    *.puml) if grep -q BROKEN "$a"; then echo "Error line 3 in file: $a"; rc=200; fi ;;
  esac
done
exit $rc
"""


def fake_plantuml(tmp_path: Path) -> str:
    """Write the fake executable and return its path."""
    exe = tmp_path / "plantuml"
    exe.write_text(FAKE_PLANTUML)
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    return str(exe)


def test_valid_diagram_with_renders_passes(tmp_path, capsys):
    """A parsing diagram with both renders committed produces no findings.

    Given:
        - ``a.puml`` that parses, plus ``a.svg`` and ``a.png``.
        - Baseline: the fake plantuml exits 0 for sources without BROKEN.
    When:
        ``main`` runs on ``a.puml``.
    Then:
        - The exit status is 0.
        - Nothing is printed.
    """
    for ext in ("puml", "svg", "png"):
        (tmp_path / f"a.{ext}").write_text("@startuml\n@enduml\n")

    status = check_uml.main(["--plantuml", fake_plantuml(tmp_path), str(tmp_path / "a.puml")])

    assert status == 0
    assert capsys.readouterr().out == ""


def test_syntax_error_and_missing_svg_are_reported(tmp_path, capsys):
    """A broken source is located by line and a missing SVG is flagged.

    Given:
        - ``bad.puml`` containing BROKEN, with ``bad.svg`` and ``bad.png``.
        - ``norender.puml`` that parses, with only ``norender.png``.
        - Baseline: the fake plantuml reports "Error line 3" for BROKEN.
    When:
        ``main`` runs on both sources.
    Then:
        - The exit status is 1.
        - ``bad.puml:3: UM001`` is reported.
        - ``norender.puml:1: UM002 missing render norender.svg`` is reported.
        - Exactly two findings are printed.
    """
    (tmp_path / "bad.puml").write_text("@startuml\nA -> B\nBROKEN ((\n@enduml\n")
    (tmp_path / "bad.svg").write_text("<svg/>")
    (tmp_path / "bad.png").write_bytes(b"png")
    (tmp_path / "norender.puml").write_text("@startuml\n@enduml\n")
    (tmp_path / "norender.png").write_bytes(b"png")

    status = check_uml.main([
        "--plantuml", fake_plantuml(tmp_path),
        str(tmp_path / "bad.puml"), str(tmp_path / "norender.puml"),
    ])

    out = capsys.readouterr().out.strip().splitlines()
    assert status == 1
    assert any(line.startswith(f"{tmp_path / 'bad.puml'}:3: UM001") for line in out)
    assert f"{tmp_path / 'norender.puml'}:1: UM002 missing render norender.svg" in out
    assert len(out) == 2
