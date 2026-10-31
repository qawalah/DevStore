import datetime as dt
import json

import pytest

from devstore_manager import actions, store

NOW = dt.datetime(2026, 10, 31, 12, 0, tzinfo=dt.timezone.utc)


def nas(url="http://nas:8081", error=None, failed=0, last_scan="2026-10-31T11:56:00Z", **apps):
    return {"nas": {"url": url, "checked": "2026-10-31T11:58:00Z", "lastScan": last_scan, "failed": failed, "error": error,
                    "apps": {repo: {"name": repo.split("/")[1] + "-server", "latest": "1.8.0", "container": None,
                                    "publishedAt": "2026-10-31T10:00:00Z", "status": status}
                             for repo, status in apps.items()}}}


def rows(view):
    return {r["repo"]: (r["kind"], r["text"]) for r in view["apps"]}


def test_off_when_the_updater_has_no_nas_section():
    v = store.build_nas({}, NOW)
    assert v["configured"] is False
    assert v["apps"] == []
    assert v["header"]["kind"] == "none"
    assert "Settings" in v["header"]["sub"]
    assert v["problems"] == []


def test_off_but_still_lists_newest_versions():
    v = store.build_nas(nas(url=None, **{"qawalah/werd": "unknown"}), NOW)
    assert v["configured"] is False
    assert rows(v) == {"qawalah/werd": ("none", "Newest version 1.8.0")}
    assert v["problems"] == []


def test_each_status_in_plain_words():
    v = store.build_nas(nas(**{"qawalah/a": "ok", "qawalah/b": "pending", "qawalah/c": "stopped", "qawalah/d": "missing"}), NOW)
    assert v["configured"] is True
    assert rows(v) == {
        "qawalah/a": ("ok", "Running the latest (1.8.0)"),
        "qawalah/b": ("update", "Update to 1.8.0 waiting for Watchtower"),
        "qawalah/c": ("warn", "Stopped on the NAS"),
        "qawalah/d": ("none", "Not running on the NAS"),
    }
    assert v["header"] == {"kind": "ok", "title": "1 update waiting for Watchtower", "sub": "Watchtower checked 4 min ago"}
    assert [p["title"] for p in v["problems"]] == ["c-server is stopped on the NAS"]


def test_header_says_everything_is_current_or_what_waits():
    assert store.build_nas(nas(**{"qawalah/a": "ok"}), NOW)["header"]["title"] == "NAS runs the latest versions"
    assert store.build_nas(nas(**{"qawalah/a": "pending"}), NOW)["header"]["title"] == "1 update waiting for Watchtower"


def test_unreachable_nas():
    v = store.build_nas(nas(error="Can't reach Watchtower at http://nas:8081: timed out", last_scan=None,
                            **{"qawalah/a": "unknown"}), NOW)
    assert v["header"]["kind"] == "error"
    assert v["header"]["title"] == "Can't reach the NAS"
    assert "timed out" in v["header"]["sub"]
    assert rows(v) == {"qawalah/a": ("none", "Unknown · newest is 1.8.0")}
    assert v["problems"][0]["title"] == "Can't reach the NAS"


def test_rejected_token_says_where_to_fix_it():
    v = store.build_nas(nas(error="Watchtower rejected the token (HTTP 401).", **{"qawalah/a": "unknown"}), NOW)
    assert v["header"]["title"] == "Watchtower rejected the token"
    assert "Settings" in v["header"]["sub"]


def test_failed_updates_are_a_warning():
    v = store.build_nas(nas(failed=2, **{"qawalah/a": "pending"}), NOW)
    assert v["header"]["kind"] == "warn"
    assert v["header"]["title"] == "Watchtower: 2 updates failed at its last check"
    assert v["problems"][0]["title"] == v["header"]["title"]


def test_never_passes_a_token_through():
    state = nas(**{"qawalah/a": "ok"})
    state["nas"]["token"] = "s3cret"
    assert "s3cret" not in json.dumps(store.build_nas(state, NOW))


def test_view_carries_nas_and_its_problems():
    v = store.build_view({"apps": []}, nas(error="Can't reach Watchtower at http://nas:8081: refused", **{"qawalah/a": "unknown"}),
                         {"apps": {}}, {}, {}, NOW)
    assert v["nas"]["configured"] is True
    assert v["counts"]["nas"] == 1
    assert any(p["title"] == "Can't reach the NAS" for p in v["problems"])


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setattr(actions, "ROOT", tmp_path)
    (tmp_path / "requests").mkdir()
    started = []
    monkeypatch.setattr(actions, "start_updater", lambda: started.append(1) or True)
    return tmp_path, started


def bodies(root_dir):
    return [json.loads(f.read_text(encoding="utf-8")) for f in sorted((root_dir / "requests").glob("*.json"))]


def test_set_nas_writes_a_request_and_starts_the_updater(root):
    path, started = root
    actions.set_nas(" http://192.168.1.20:8081 ", "s3cret ")
    assert bodies(path) == [{"action": "set-nas", "url": "http://192.168.1.20:8081", "token": "s3cret"}]
    assert started == [1]


def test_set_nas_off(root):
    path, _ = root
    actions.set_nas("", "")
    assert bodies(path) == [{"action": "set-nas", "url": "", "token": ""}]


@pytest.mark.parametrize("url,token", [
    ("ftp://nas", "x"), ("http://nas/v1/containers", "x"), ("nas:8081", "x"), ("http://n as", "x"),
    ("http://nas:8081", "a b"), ("http://nas:8081", "x" * 257),
])
def test_set_nas_rejects_bad_input(root, url, token):
    path, started = root
    with pytest.raises(ValueError):
        actions.set_nas(url, token)
    assert bodies(path) == [] and started == []
