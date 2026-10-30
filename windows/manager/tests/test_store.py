import datetime as dt

from devstore_manager import store

NOW = dt.datetime(2026, 10, 30, 12, 0, tzinfo=dt.timezone.utc)
T = "2026-10-30T11:58:00Z"


def catalog(**apps):
    return {"apps": {repo: {"repo": repo, "name": repo.split("/")[1].lower(), "displayName": repo.split("/")[1],
                             "description": f"About {repo}", "latest": "1.0.0", "type": "gui",
                             "icon": None, "screenshots": [], **extra}
                     for repo, extra in apps.items()}}


def view(config=None, state=None, cat=None, services=None, pending=None, now=NOW):
    return store.build_view(config or {"apps": []}, state or {}, cat or {"apps": {}}, services or {},
                            pending or {}, now)


def app(v, repo):
    return next(a for a in v["apps"] if a["repo"].lower() == repo.lower())


def test_catalog_app_not_installed_offers_install():
    v = view(cat=catalog(**{"qawalah/Tool": {}}))
    a = app(v, "qawalah/Tool")
    assert a["installed"] is False
    assert a["status"] == {"kind": "none", "text": "Not installed", "detail": "", "short": "Not installed"}
    assert a["actions"] == ["install"]


def test_installed_up_to_date_gui_app():
    v = view(config={"apps": [{"repo": "qawalah/tool"}]},
             state={"lastRun": T, "lastRunResult": "ok",
                    "apps": {"qawalah/tool": {"name": "tool", "type": "gui", "installed": "1.0.0",
                                              "latest": "1.0.0", "status": "ok", "displayName": "Tool"}}},
             cat=catalog(**{"qawalah/Tool": {}}))
    a = app(v, "qawalah/tool")
    assert a["installed"] is True
    assert a["status"]["kind"] == "ok" and a["status"]["text"] == "Installed · up to date"
    assert a["actions"] == ["open", "data", "remove"]
    assert v["counts"] == {"installed": 1, "attention": 0}


def test_config_app_without_state_is_installing():
    v = view(config={"apps": [{"repo": "qawalah/new"}]}, cat=catalog(**{"qawalah/new": {}}))
    assert app(v, "qawalah/new")["status"]["kind"] == "busy"
    assert app(v, "qawalah/new")["status"]["text"] == "Installing…"


def test_pending_requests_show_progress():
    v = view(cat=catalog(**{"qawalah/a": {}}), pending={"qawalah/a": "install"})
    assert app(v, "qawalah/a")["status"]["text"] == "Installing…"
    assert app(v, "qawalah/a")["actions"] == []
    v = view(config={"apps": [{"repo": "qawalah/a"}]},
             state={"apps": {"qawalah/a": {"name": "a", "type": "gui", "installed": "1.0.0", "status": "ok"}}},
             pending={"qawalah/a": "remove"})
    assert app(v, "qawalah/a")["status"]["text"] == "Removing…"


def test_service_states_and_actions():
    st = {"apps": {"qawalah/svc": {"name": "svc", "type": "service", "installed": "2.0.0", "status": "ok"}}}
    v = view(config={"apps": [{"repo": "qawalah/svc"}]}, state=st, services={"devstore-svc": "Running"})
    a = app(v, "qawalah/svc")
    assert a["status"]["text"] == "Running · up to date"
    assert a["actions"] == ["stop", "restart", "data", "remove"]
    v = view(config={"apps": [{"repo": "qawalah/svc"}]}, state=st, services={"devstore-svc": "Stopped"})
    a = app(v, "qawalah/svc")
    assert a["status"]["kind"] == "warn" and a["status"]["text"] == "Stopped"
    assert a["actions"][0] == "start"


def test_problems_are_explained_in_plain_words():
    st = {"lastRun": T, "lastRunResult": "1 error(s)", "apps": {
        "qawalah/a": {"name": "a", "type": "service", "installed": "1.2.0", "latest": "1.3.0",
                      "status": "rolledback", "bad": ["1.3.0"],
                      "lastError": "v1.3.0 didn't stay running for 30 s; rolled back to v1.2.0."},
        "qawalah/b": {"name": "b", "type": "gui", "status": "error",
                      "lastError": "GitHub token rejected (HTTP 401). It may have expired."},
        "qawalah/c": {"name": "c", "type": "gui", "installed": "1.0.0", "latest": "1.1.0", "status": "pending"},
    }}
    v = view(config={"apps": [{"repo": r} for r in ("qawalah/a", "qawalah/b", "qawalah/c")]}, state=st)
    a, b, c = app(v, "qawalah/a"), app(v, "qawalah/b"), app(v, "qawalah/c")
    assert a["status"]["kind"] == "error"
    assert a["status"]["text"] == "Version 1.3.0 failed to start, so 1.2.0 is still running"
    assert b["status"]["text"] == "Couldn't install"
    assert "DevStoreSetup.exe" in b["status"]["detail"]
    assert c["status"]["kind"] == "warn" and c["status"]["text"] == "Update ready: close the app to finish"
    assert v["counts"]["attention"] == 2
    assert [p["repo"] for p in v["problems"]] == ["qawalah/a", "qawalah/b"]


def test_restart_pending():
    st = {"apps": {"qawalah/t": {"name": "t", "type": "gui", "installed": "1.1.0", "status": "ok", "restartPending": True}}}
    a = app(view(config={"apps": [{"repo": "qawalah/t"}]}, state=st), "qawalah/t")
    assert a["status"]["kind"] == "warn"
    assert a["status"]["text"] == "Updated to 1.1.0: restart the app to use it"
    assert a["status"]["short"] == "Restart to update"


def test_updater_summary():
    assert view()["updater"]["kind"] == "none"
    assert view()["updater"]["title"] == "Waiting for first check"
    ok = view(state={"lastRun": T, "lastRunResult": "ok"})["updater"]
    assert ok["kind"] == "ok" and ok["title"] == "Up to date" and ok["sub"] == "Checked 2 min ago"
    stale = view(state={"lastRun": "2026-10-30T09:00:00Z", "lastRunResult": "ok"})["updater"]
    assert stale["kind"] == "warn" and stale["title"] == "Not checked recently"
    failed = view(state={"lastRun": T, "lastRunResult": "failed: token.dat not found"})["updater"]
    assert failed["kind"] == "error"


def test_catalog_error_is_a_problem():
    v = view(state={"lastRun": T, "lastRunResult": "ok", "catalogError": "HTTP 403"})
    assert v["problems"][0]["title"] == "Couldn't list your GitHub apps"


def test_manager_itself_is_not_removable_and_sorted_last():
    st = {"apps": {"qawalah/DevStore": {"name": "devstore-manager", "type": "gui", "installed": "2.0.0", "status": "ok"},
                   "qawalah/zed": {"name": "zed", "type": "gui", "installed": "1.0.0", "status": "ok"}}}
    v = view(config={"apps": [{"repo": "qawalah/DevStore"}, {"repo": "qawalah/zed"}]}, state=st)
    assert [a["repo"] for a in v["apps"]] == ["qawalah/zed", "qawalah/DevStore"]
    me = app(v, "qawalah/DevStore")
    assert me["isSelf"] is True and me["actions"] == ["data"]


def test_service_with_unknown_state_offers_restart():
    st = {"apps": {"qawalah/svc": {"name": "svc", "type": "service", "installed": "2.0.0", "status": "ok"}}}
    a = app(view(config={"apps": [{"repo": "qawalah/svc"}]}, state=st), "qawalah/svc")
    assert a["actions"] == ["restart", "data", "remove"]


def test_list_state_entries_from_updater_1_0_0_are_repaired():
    st = {"apps": {"qawalah/DevStore": [None, None, {"name": "devstore-manager", "type": "gui",
                                                     "installed": "1.0.0", "status": "ok"}]}}
    a = app(view(config={"apps": [{"repo": "qawalah/DevStore"}]}, state=st), "qawalah/DevStore")
    assert a["installed"] is True


def test_activity_entries():
    lines = ["2026-10-30 11:50:11 [svc] v1.3.0 didn't stay running for 30 s; rolled back to v1.2.0.",
             "2026-10-30 11:55:00 [-] agent installed/upgraded",
             "garbage line"]
    entries = store.parse_activity(lines)
    assert entries[0] == {"time": "2026-10-30 11:55:00", "app": "", "text": "agent installed/upgraded"}
    assert entries[1]["app"] == "svc"
    assert len(entries) == 2
