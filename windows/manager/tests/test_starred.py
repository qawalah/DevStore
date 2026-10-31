from devstore_manager import starred


def entry(repo, tag=None):
    return {"repo": repo, "description": f"About {repo}", "url": f"https://github.com/{repo}", "avatar": None,
            "latest": {"tag": tag, "title": tag, "publishedAt": "2026-10-30T10:00:00Z", "notes": "n",
                       "url": f"https://github.com/{repo}/releases", "assets": []} if tag else None}


def test_first_time_nothing_is_new_and_versions_are_remembered():
    data = {"updated": "2026-10-31T00:00:00Z", "repos": [entry("a/one", "v1"), entry("b/two")]}
    view, seen = starred.build(data, {})
    assert [i["repo"] for i in view["items"]] == ["a/one", "b/two"]
    assert view["newCount"] == 0
    assert seen == {"a/one": "v1"}


def test_a_new_version_is_flagged_until_seen():
    data = {"repos": [entry("a/one", "v2")]}
    view, seen = starred.build(data, {"a/one": "v1"})
    assert view["items"][0]["isNew"] is True and view["newCount"] == 1
    assert seen == {"a/one": "v1"}
    assert starred.mark_seen(seen, "a/one", "v2") == {"a/one": "v2"}


def test_items_with_releases_first_newest_first():
    a = entry("a/old", "v1"); a["latest"]["publishedAt"] = "2026-01-01T00:00:00Z"
    b = entry("b/new", "v1"); b["latest"]["publishedAt"] = "2026-10-01T00:00:00Z"
    view, _ = starred.build({"repos": [entry("c/none"), a, b]}, {})
    assert [i["repo"] for i in view["items"]] == ["b/new", "a/old", "c/none"]


def test_error_and_missing_file():
    assert starred.build({}, {})[0] == {"items": [], "newCount": 0, "updated": "", "error": ""}
    assert starred.build({"error": "HTTP 500", "repos": []}, {})[0]["error"] == "HTTP 500"


def test_only_github_links_may_be_opened():
    assert starred.safe_url("https://github.com/a/b/releases/download/v1/x.exe")
    assert not starred.safe_url("http://github.com/a/b")
    assert not starred.safe_url("https://github.com.evil.example/x")
    assert not starred.safe_url("javascript:alert(1)")
    assert not starred.safe_url("file:///C:/Windows/System32/calc.exe")
