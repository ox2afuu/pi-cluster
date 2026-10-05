#!/usr/bin/env python3
"""Fail when a text file contains an emoji (repository convention: none).

Usage:
    check_no_emoji.py FILE [FILE ...]

Binary files (anything containing a NUL byte in its first 8 KiB, or not
valid UTF-8) are skipped. Typographic characters that are not emoji, such
as arrows, dashes and box-drawing characters, are allowed.

Output: ``path:line: EM001 emoji U+1F680 'ROCKET'``. Exit status is 1 when
anything is reported, 0 otherwise.
"""

from __future__ import annotations

import sys
import unicodedata
from pathlib import Path

#: Inclusive code point ranges treated as emoji.
EMOJI_RANGES: tuple[tuple[int, int], ...] = (
    (0x1F000, 0x1FAFF),  # mahjong .. symbols and pictographs extended-A, flags
    (0x2600, 0x26FF),    # miscellaneous symbols (sun, warning sign, ...)
    (0x2700, 0x27BF),    # dingbats (check marks, sparkles, crosses, ...)
    (0x231A, 0x231B),    # watch, hourglass
    (0x23E9, 0x23F3),    # media controls, alarm clock, hourglass
    (0x23F8, 0x23FA),    # pause, stop, record
    (0x2B05, 0x2B07),    # emoji-presentation arrows
    (0x2B1B, 0x2B1C),    # large squares
    (0x2B50, 0x2B50),    # star
    (0x2B55, 0x2B55),    # heavy circle
    (0x3030, 0x3030),    # wavy dash
    (0x303D, 0x303D),    # part alternation mark
    (0x3297, 0x3297),    # circled ideograph congratulation
    (0x3299, 0x3299),    # circled ideograph secret
    (0xFE0F, 0xFE0F),    # variation selector-16 (emoji presentation)
    (0x20E3, 0x20E3),    # combining enclosing keycap
    (0xE0020, 0xE007F),  # tag characters (subdivision flags)
)


def is_emoji(ch: str) -> bool:
    """Return whether a single character is in ``EMOJI_RANGES``."""
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in EMOJI_RANGES)


def read_text(path: Path) -> str | None:
    """Return the file's text, or ``None`` if it is binary or unreadable."""
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def check_file(path: Path) -> list[str]:
    """Return one finding line per emoji in ``path``."""
    text = read_text(path)
    if text is None:
        return []
    out = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for ch in line:
            if is_emoji(ch):
                name = unicodedata.name(ch, "UNNAMED")
                out.append(f"{path}:{lineno}: EM001 emoji U+{ord(ch):04X} '{name}'")
    return out


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns the process exit status."""
    args = sys.argv[1:] if argv is None else argv
    findings: list[str] = []
    for name in args:
        path = Path(name)
        if path.is_file():
            findings.extend(check_file(path))
    for f in findings:
        print(f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
