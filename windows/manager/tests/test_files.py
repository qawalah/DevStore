import json

from devstore_manager import files


def test_load_json_tolerates_missing_empty_corrupt_and_bom(tmp_path):
    p = tmp_path / "state.json"
    assert files.load_json(p, {"x": 1}) == {"x": 1}
    p.write_text("")
    assert files.load_json(p, {}) == {}
    p.write_text('{"apps": {')
    assert files.load_json(p, {"d": True}) == {"d": True}
    p.write_text("[1, 2]")
    assert files.load_json(p, {}) == {}
    p.write_bytes(b"\xef\xbb\xbf" + json.dumps({"ok": 1}).encode())
    assert files.load_json(p, {}) == {"ok": 1}


def test_read_log_lines_reads_newest_two_files(tmp_path):
    (tmp_path / "updater-2026-08.log").write_text("old\n", encoding="utf-8")
    (tmp_path / "updater-2026-09.log").write_text("sep\n", encoding="utf-8")
    (tmp_path / "updater-2026-10.log").write_text("﻿oct1\noct2\n", encoding="utf-8")
    assert files.read_log_lines(tmp_path) == ["sep", "oct1", "oct2"]
    assert files.read_log_lines(tmp_path / "missing") == []
