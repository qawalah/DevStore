import datetime as dt
import json

from devstore_manager import model

NOW = dt.datetime(2026, 10, 28, 12, 0, tzinfo=dt.timezone.utc)


def test_load_json_tolerates_missing_empty_corrupt_and_bom(tmp_path):
    p = tmp_path / "state.json"
    assert model.load_json(p, {"x": 1}) == {"x": 1}
    p.write_text("")
    assert model.load_json(p, {}) == {}
    p.write_text('{"apps": {')
    assert model.load_json(p, {"d": True}) == {"d": True}
    p.write_text("[1, 2]")
    assert model.load_json(p, {}) == {}
    p.write_bytes(b"\xef\xbb\xbf" + json.dumps({"ok": 1}).encode())
    assert model.load_json(p, {}) == {"ok": 1}


def test_build_rows_follows_config_order_and_handles_missing_state():
    config = {"apps": [{"repo": "qawalah/devstore"}, {"repo": "qawalah/new-app"}]}
    state = {"apps": {"Qawalah/DevStore": {"name": "devstore-manager", "type": "gui", "installed": "1.0.0",
                                           "latest": "1.0.0", "status": "ok", "displayName": "DevStore Manager"}}}
    rows = model.build_rows(config, state, {})
    assert [r.repo for r in rows] == ["qawalah/devstore", "qawalah/new-app"]
    assert rows[0].display_name == "DevStore Manager"
    assert rows[0].status == "Up to date"
    assert rows[1].name == "new-app"
    assert rows[1].installed == ""
    assert rows[1].status == "Not installed yet"
    assert rows[1].kind == "none"


def test_build_rows_with_garbage_config():
    assert model.build_rows({"apps": "nope"}, {"apps": []}, {}) == []
    assert model.build_rows({}, {}, {}) == []
    rows = model.build_rows({"apps": [None, {"x": 1}, {"repo": "a/b"}]}, {}, {})
    assert [r.repo for r in rows] == ["a/b"]


def test_status_text_mapping():
    assert model.status_text({"status": "ok", "type": "gui"}, None) == "Up to date"
    assert model.status_text({"status": "ok", "type": "service"}, "Running") == "Up to date, running"
    assert model.status_text({"status": "ok", "type": "service"}, "Stopped") == "Up to date, stopped"
    assert model.status_text({"status": "pending", "latest": "1.2.0"}, None) == "v1.2.0 waiting for app to close"
    assert model.status_text({"status": "rolledback", "bad": ["1.1.0", "1.3.0"]}, None) == "v1.3.0 failed, rolled back"
    assert model.status_text({"status": "error", "lastError": "HTTP 401"}, None) == "Error: HTTP 401"
    assert model.status_text({"status": "error"}, None) == "Error"
    assert model.status_text(None, None) == "Not installed yet"


def test_status_kind():
    assert model.status_kind({"status": "ok"}) == "ok"
    assert model.status_kind({"status": "pending"}) == "pending"
    assert model.status_kind({"status": "rolledback"}) == "error"
    assert model.status_kind({"status": "error"}) == "error"
    assert model.status_kind(None) == "none"


def test_filter_log_limits_to_app_and_count():
    lines = [f"2026-10-28 10:{i:02d}:00 [hello] line {i}" for i in range(60)]
    lines.insert(5, "2026-10-28 10:00:00 [other] nope")
    lines.insert(6, "2026-10-28 10:00:00 [hello-world] not me either")
    out = model.filter_log(lines, "hello", limit=50)
    assert len(out) == 50
    assert out[-1].endswith("line 59")
    assert all("[hello]" in line for line in out)


def test_read_log_lines_reads_newest_two_files(tmp_path):
    (tmp_path / "updater-2026-08.log").write_text("old\n", encoding="utf-8")
    (tmp_path / "updater-2026-09.log").write_text("sep\n", encoding="utf-8")
    (tmp_path / "updater-2026-10.log").write_text("﻿oct1\noct2\n", encoding="utf-8")
    assert model.read_log_lines(tmp_path) == ["sep", "oct1", "oct2"]
    assert model.read_log_lines(tmp_path / "missing") == []


def test_format_time():
    assert model.format_time(None, NOW) == "never"
    assert model.format_time("garbage", NOW) == "never"
    local_now = NOW.astimezone()
    same_day = local_now.replace(hour=9, minute=5).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert model.format_time(same_day, NOW) == "09:05"
    other = (local_now - dt.timedelta(days=3)).replace(hour=9, minute=5).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert model.format_time(other, NOW).endswith("09:05")
    assert len(model.format_time(other, NOW)) > 5


def test_footer_text():
    assert model.footer_text({}, NOW) == "The updater hasn't run yet. It runs every 10 minutes, or press Check now."
    t = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
    hhmm = NOW.astimezone().strftime("%H:%M")
    assert model.footer_text({"lastRun": t, "lastRunResult": "ok"}, NOW) == f"Last check {hhmm}: all good. Next check within 10 minutes."
    assert model.footer_text({"lastRun": t, "lastRunResult": "2 error(s)"}, NOW) == f"Last check {hhmm}: 2 error(s). Next check within 10 minutes."


def test_service_name():
    assert model.service_name("my-svc") == "devstore-my-svc"
