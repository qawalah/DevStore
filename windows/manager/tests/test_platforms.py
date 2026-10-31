import datetime as dt

from devstore_manager import store

NOW = dt.datetime(2026, 10, 31, 12, 0, tzinfo=dt.timezone.utc)


def shots(platform, n):
    return [{"path": f"store/screenshots/{platform}/{i}.png", "sha": str(i), "file": f"catalog\\q.platforms\\{platform}-{i}.png"}
            for i in range(1, n + 1)]


WERD = {"repo": "qawalah/Werd", "name": "werd-server", "displayName": "Werd Server", "description": "Family app",
        "latest": "1.8.0", "publishedAt": "2026-10-30T09:00:00Z", "type": "service", "windows": True,
        "screenshots": ["catalog\\q\\screenshot-1.png"],
        "android": {"version": "2.3", "code": 57, "publishedAt": "2026-10-29T08:00:00Z"},
        "docker": {"version": "1.8.0", "publishedAt": "2026-10-31T10:00:00Z", "image": "ghcr.io/qawalah/werd-server"},
        "platformShots": {"windows": [], "android": shots("android", 2), "docker": shots("docker", 1)}}


def build(cat, state=None, config=None):
    return store.build_view(config or {"apps": []}, state or {}, {"apps": cat}, {}, {}, NOW)


def app(v, repo):
    return next(a for a in v["apps"] if a["repo"].lower() == repo.lower())


def test_each_platform_gets_its_version_date_status_and_screenshots():
    nas = {"nas": {"url": "http://nas:8081", "lastScan": "2026-10-31T11:00:00Z", "failed": 0, "error": None,
                   "apps": {"qawalah/Werd": {"name": "werd-server", "latest": "1.8.0", "status": "ok"}}}}
    a = app(build({"qawalah/Werd": WERD}, state=nas), "qawalah/Werd")
    p = {x["key"]: x for x in a["platforms"]}
    assert [x["key"] for x in a["platforms"]] == ["windows", "android", "docker"]
    assert p["windows"]["label"] == "Windows" and p["windows"]["version"] == "1.8.0"
    assert p["windows"]["shots"] == ["catalog\\q\\screenshot-1.png"]
    assert p["windows"]["text"] == "Not installed"
    assert p["android"]["version"] == "2.3" and p["android"]["date"] == "2026-10-29T08:00:00Z"
    assert p["android"]["text"] == "On your phone through Obtainium"
    assert p["android"]["shots"] == ["catalog\\q.platforms\\android-1.png", "catalog\\q.platforms\\android-2.png"]
    assert p["docker"]["label"] == "Docker (NAS)"
    assert (p["docker"]["kind"], p["docker"]["text"]) == ("ok", "Running the latest (1.8.0)")
    assert p["docker"]["shots"] == ["catalog\\q.platforms\\docker-1.png"]


def test_windows_folder_screenshots_win_over_release_ones():
    entry = {**WERD, "platformShots": {"windows": shots("windows", 1)}}
    a = app(build({"qawalah/Werd": entry}), "qawalah/Werd")
    assert a["platforms"][0]["shots"] == ["catalog\\q.platforms\\windows-1.png"]


def test_docker_without_nas_status_shows_the_newest_version():
    a = app(build({"qawalah/Werd": WERD}), "qawalah/Werd")
    docker = next(x for x in a["platforms"] if x["key"] == "docker")
    assert (docker["kind"], docker["text"]) == ("none", "Newest version 1.8.0")


def test_phone_and_nas_only_apps_have_nothing_to_install_on_the_pc():
    entry = {"repo": "qawalah/Phone", "name": "phone", "displayName": "Phone", "windows": False, "latest": None,
             "android": {"version": "1.0", "code": 1, "publishedAt": "2026-10-01T00:00:00Z"}, "docker": None}
    a = app(build({"qawalah/Phone": entry}), "qawalah/Phone")
    assert [x["key"] for x in a["platforms"]] == ["android"]
    assert a["actions"] == []
    assert a["type"] == "Android"
    assert a["status"]["text"] == "Android app"
    assert a["status"]["kind"] == "none"


def test_old_catalog_entries_without_platform_fields_still_list_windows():
    entry = {"repo": "qawalah/Tool", "name": "tool", "displayName": "Tool", "latest": "1.0.0", "type": "gui", "screenshots": []}
    a = app(build({"qawalah/Tool": entry}), "qawalah/Tool")
    assert [x["key"] for x in a["platforms"]] == ["windows"]
    assert a["actions"] == ["install"]
