"""Starred repos: watch only. Turns the updater's starred.json into what the
window shows and tracks which versions this Windows user has already seen.
DevStore never downloads or runs anything from these repos; links open in the
browser, and only https://github.com links are allowed."""
from __future__ import annotations

from typing import Any


def safe_url(url: Any) -> bool:
    return isinstance(url, str) and url.startswith("https://github.com/")


def build(data: dict, seen: dict) -> tuple[dict, dict]:
    """(view, seen). A repo seen for the first time counts as already seen, so only
    versions released after DevStore started watching are marked New."""
    data = data if isinstance(data, dict) else {}
    seen = dict(seen) if isinstance(seen, dict) else {}
    items = []
    for r in data.get("repos") or []:
        if not isinstance(r, dict) or not r.get("repo"):
            continue
        latest = r.get("latest") if isinstance(r.get("latest"), dict) else None
        tag = (latest or {}).get("tag")
        if tag and r["repo"] not in seen:
            seen[r["repo"]] = tag
        items.append({**r, "latest": latest, "isNew": bool(tag) and seen.get(r["repo"]) != tag})
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
