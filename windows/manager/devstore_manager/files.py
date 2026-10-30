"""Reading the updater's files safely: they may be missing, half-written by an
older updater, or carry a UTF-8 BOM from Windows PowerShell."""
from __future__ import annotations

import json
from pathlib import Path


def load_json(path: Path, default: dict) -> dict:
    """Missing, empty, corrupt or non-object JSON -> default. Accepts a UTF-8 BOM."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default
    return data if isinstance(data, dict) else default


def read_log_lines(log_dir: Path) -> list[str]:
    """Lines from the two newest updater-YYYY-MM.log files, oldest first."""
    try:
        files = sorted(Path(log_dir).glob("updater-*.log"))[-2:]
    except OSError:
        return []
    lines: list[str] = []
    for f in files:
        try:
            lines.extend(f.read_text(encoding="utf-8-sig", errors="replace").splitlines())
        except OSError:
            continue
    return lines
