"""Shared pytest setup: make tools/docs importable as top-level modules."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
