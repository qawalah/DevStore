"""Starred repos: turns the updater's starred.json into what the window shows,
tracks which versions this Windows user has already seen, and joins in the
install state of the ones installed from Starred. The updater does the
installing; links the window opens go to the browser, and only
https://github.com links are allowed."""
from __future__ import annotations

from typing import Any, Optional


def safe_url(url: Any) -> bool:
    return isinstance(url, str) and url.startswith("https://github.com/")


def safe_avatar(url: Any) -> bool:
    return isinstance(url, str) and url.startswith("https://avatars.githubusercontent.com/")


def build(data: dict, seen: dict, apps: Optional[list] = None) -> tuple[dict, dict]:
    """(view, seen). A repo seen for the first time counts as already seen, so only
    versions released after DevStore started watching are marked New. `apps` is
    the store view's app list: each item gets `app` (its status and actions) when
    it was installed from Starred, else None."""
    data = data if isinstance(data, dict) else {}
    installed = {str(a.get("repo", "")).lower(): a for a in (apps or []) if isinstance(a, dict) and a.get("starred")}
    seen = dict(seen) if isinstance(seen, dict) else {}
    items = []
    for r in data.get("repos") or []:
        if not isinstance(r, dict) or not r.get("repo"):
            continue
        latest = r.get("latest") if isinstance(r.get("latest"), dict) else None
        tag = (latest or {}).get("tag")
        if tag and r["repo"] not in seen:
            seen[r["repo"]] = tag
        app = installed.get(str(r["repo"]).lower())
        windows = (latest or {}).get("windows")
        items.append({**r, "latest": latest, "isNew": bool(tag) and seen.get(r["repo"]) != tag,
                      "installable": isinstance(windows, dict) and bool(windows.get("name")),
                      "app": {k: app[k] for k in ("repo", "status", "actions", "installedVersion", "updates")} if app else None})
    items.sort(key=lambda i: (i["latest"] is None, -_stamp((i["latest"] or {}).get("publishedAt"))))
    view = {"items": items, "newCount": sum(1 for i in items if i["isNew"]),
            "updated": str(data.get("updated") or ""), "error": str(data.get("error") or "")}
    return view, seen


def mark_seen(seen: dict, repo: str, tag: str) -> dict:
    return {**seen, repo: tag}


def _stamp(value: Any) -> float:
    import datetime as dt
    try:
        return dt.datetime.strptime(str(value), "%Y-%m-%dT%H:%M:%SZ").timestamp()
    except ValueError:
        return 0.0
