"""Turns the updater's files (config, state, catalog, requests) into what the
store window shows, in plain language. Pure logic: no Windows APIs, unit-tested."""
from __future__ import annotations

import datetime as dt
import re
from typing import Any, Optional

SELF_NAME = "devstore-manager"
UPDATE_MODES = ("auto", "download", "notify")
STALE_AFTER = dt.timedelta(minutes=30)
_LOG_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[(.*?)\] (.*)$")


def _as_dict(v: Any) -> Optional[dict]:
    if isinstance(v, list):  # entries saved as [null, null, {...}] by updater 1.0.0
        v = next((x for x in reversed(v) if isinstance(x, dict)), None)
    return v if isinstance(v, dict) else None


def _by_repo(d: Any) -> dict[str, dict]:
    if not isinstance(d, dict):
        return {}
    out = {}
    for k, v in d.items():
        v = _as_dict(v)
        if v is not None:
            out[str(k).lower()] = {**v, "_repo": str(k)}
    return out


def _version(v: Any) -> tuple:
    try:
        return tuple(int(x) for x in str(v).split("-")[0].split("."))
    except ValueError:
        return ()


def _parse_utc(value: Any) -> Optional[dt.datetime]:
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def ago(t: dt.datetime, now: dt.datetime) -> str:
    minutes = int((now - t).total_seconds() // 60)
    if minutes < 1:
        return "just now"
    if minutes < 60:
        return f"{minutes} min ago"
    hours = minutes // 60
    if hours < 24:
        return f"{hours} h ago"
    return t.astimezone().strftime("%b %d %H:%M")


def explain(error: str) -> str:
    """Updater error -> what it means and what to do."""
    e = error or ""
    low = e.lower()
    if "401" in e or "token rejected" in low:
        return "Your GitHub token was rejected; it may have expired. Run DevStoreSetup.exe again and paste a new token."
    if "token.dat" in low:
        return "DevStore has no GitHub token on this PC. Run DevStoreSetup.exe again."
    if "404" in e or "can't read it" in low:
        return "DevStore can't see this repo. Check that your GitHub token has access to it."
    if "no windows-v release" in low:
        return "This repo has no Windows release yet. Bump the version in devstore.json and push to main."
    if "sha256" in low or "hash" in low:
        return "The download was damaged. DevStore tries again automatically."
    return e


def _status(s: Optional[dict], in_config: bool, pending: Optional[str], service: Optional[str],
            running: bool = False) -> dict:
    def st(kind: str, text: str, detail: str = "", short: str = "") -> dict:
        return {"kind": kind, "text": text, "detail": detail, "short": short or text}

    if pending == "install":
        return st("busy", "Installing…")
    if pending == "remove":
        return st("busy", "Removing…")
    if not in_config:
        return st("none", "Not installed")
    if not s:
        return st("busy", "Installing…")
    status, installed = s.get("status"), s.get("installed")
    if status == "rolledback":
        bad = (s.get("bad") or ["?"])[-1]
        return st("error", f"Version {bad} failed to start, so {installed} is still running",
                  "DevStore kept the working version. Push a fixed version and it's installed automatically.",
                  f"Update failed · still on {installed}")
    if status == "error":
        return st("error", "Couldn't update" if installed else "Couldn't install", explain(s.get("lastError") or ""))
    if not installed:
        return st("busy", "Installing…")
    if status == "pending":
        return st("warn", "Update ready: close the app to finish", short="Close the app to update")
    if status == "available":
        return st("update", f"Update available: {s.get('latest', '?')}", short="New version")
    if status == "ready":
        return st("update", f"Update downloaded: {s.get('latest', '?')}, ready to install", short="Downloaded")
    if s.get("restartPending"):
        return st("warn", f"Updated to {installed}: restart the app to use it", short="Restart to update")
    if s.get("channelMissing") and str(s.get("channel", "")).startswith("pr-"):
        pr = str(s["channel"])[3:]
        return st("warn", f"PR #{pr} has no test build now, so the stable release is installed",
                  "The pull request was closed or hasn't been built yet. Switch Version back to Stable, or wait for its build.",
                  short="Test build not available")
    latest = s.get("latest")
    if (latest and _test_build(installed) is None and _version(latest) > _version(installed)
            and latest not in (s.get("bad") or [])):
        return st("busy", f"Updating to {latest}…")
    test_pr = _test_build(installed)
    if test_pr is not None:
        return st("ok", f"Test build of PR #{test_pr} · up to date", short=f"Test build #{test_pr}")
    if s.get("type") == "service":
        if service == "Running":
            return st("ok", "Running · up to date")
        if service == "Stopped":
            return st("warn", "Stopped")
        if service in ("Starting", "Stopping"):
            return st("busy", f"{service}…")
    if running:
        return st("ok", "Running · up to date")
    return st("ok", "Installed · up to date")


def _test_build(version: Any) -> Optional[int]:
    """PR number if `version` is a pull-request test build like '1.3.0-pr12.9'."""
    m = re.match(r"^\d+\.\d+\.\d+-pr(\d+)\.\d+$", str(version or ""))
    return int(m.group(1)) if m else None


def _actions(s: Optional[dict], in_config: bool, pending: Optional[str], service: Optional[str], is_self: bool,
             running: bool = False) -> list[str]:
    if pending:
        return []
    if not in_config:
        return ["install"]
    if not s or not s.get("installed"):
        return [] if is_self else ["remove"]
    acts = ["update"] if s.get("status") in ("available", "ready") else []
    if s.get("type") == "service":
        if service == "Running":
            acts += ["stop", "restart"]
        elif service == "Stopped":
            acts.append("start")
        else:
            acts.append("restart")
    elif is_self:
        if s.get("restartPending"):
            acts.append("relaunch")   # DevStore restarting itself to use its update
    elif running:
        acts += ["relaunch", "close"]  # relaunch = force close, then open again
    else:
        acts.append("open")
    acts.append("data")
    if not is_self:
        acts.append("remove")
    return acts


def build_view(config: dict, state: dict, catalog: dict, services: dict[str, str],
               pending: dict[str, str], now: dt.datetime, running: Optional[set] = None,
               self_version: Optional[str] = None, progress: Optional[dict] = None) -> dict:
    """Everything the window renders. `pending` maps repo -> 'install'/'remove' for
    requests the updater hasn't picked up yet; `services` maps devstore-<name> -> status;
    `running` holds the names of window apps that are open right now."""
    state = state if isinstance(state, dict) else {}
    states = _by_repo(state.get("apps"))
    cat = _by_repo((catalog or {}).get("apps") if isinstance(catalog, dict) else None)
    entries = config.get("apps") if isinstance(config, dict) else None
    entries = [e for e in (entries if isinstance(entries, list) else []) if isinstance(e, dict) and e.get("repo")]
    configured = {str(e["repo"]).lower(): str(e["repo"]) for e in entries}
    modes = {str(e["repo"]).lower(): e.get("updates") for e in entries if e.get("updates") in UPDATE_MODES}
    channels = {str(e["repo"]).lower(): str(e["channel"]) for e in entries
                if re.match(r"^(stable|pr-\d+)$", str(e.get("channel", "")))}
    default_mode = config.get("defaultUpdates") if isinstance(config, dict) else None
    default_mode = default_mode if default_mode in UPDATE_MODES else "auto"
    pend = {str(k).lower(): v for k, v in (pending or {}).items()}

    apps = []
    for key in sorted(set(configured) | set(cat) | set(states)):
        s, c = states.get(key), cat.get(key, {})
        repo = configured.get(key) or c.get("_repo") or (s or {}).get("_repo") or key
        in_config = key in configured
        name = (s or {}).get("name") or c.get("name") or repo.split("/")[-1].lower()
        app_type = (s or {}).get("type") or c.get("type") or ""
        service = services.get(f"devstore-{name}") if app_type == "service" else None
        is_self = name == SELF_NAME
        if is_self and s and s.get("restartPending") and self_version and self_version == s.get("installed"):
            s = {**s, "restartPending": False}   # this window already is the installed version
        is_running = app_type != "service" and name in (running or set())
        status = _status(s, in_config, pend.get(key), service, is_running)
        apps.append({
            "repo": repo,
            "name": name,
            "displayName": (s or {}).get("displayName") or c.get("displayName") or name,
            "description": c.get("description") or "",
            "type": {"gui": "App", "service": "Service"}.get(app_type, ""),
            "installed": bool(in_config and s and s.get("installed")),
            "installedVersion": (s or {}).get("installed") or "",
            "latest": max([v for v in (c.get("latest"), (s or {}).get("latest")) if v], key=_version, default=""),
            "status": status,
            "actions": _actions(s, in_config, pend.get(key), service, is_self, is_running),
            "running": is_running,
            "icon": c.get("icon"),
            "screenshots": c.get("screenshots") or [],
            "isSelf": is_self,
            "shared": bool(c.get("shared")),
            "owner": c.get("owner") or repo.split("/")[0],
            "updates": modes.get(key, default_mode),
            "updatesIsDefault": key not in modes,
            "channel": channels.get(key, "stable"),
            "previews": [p for p in (c.get("previews") or []) if isinstance(p, dict) and p.get("pr")],
            "testBuild": _test_build((s or {}).get("installed")),
            "exe": (s or {}).get("exe") or f"{name}.exe",
            "lastChecked": (s or {}).get("lastChecked") or "",
            "error": (s or {}).get("lastError") or "",
        })
    apps.sort(key=lambda a: (a["isSelf"], a["displayName"].lower()))

    problems = [{"repo": a["repo"], "title": f"{a['displayName']}: {a['status']['text']}", "detail": a["status"]["detail"]}
                for a in apps if a["status"]["kind"] == "error"]
    if state.get("catalogError"):
        problems.insert(0, {"repo": "", "title": "Couldn't list your GitHub apps", "detail": explain(state["catalogError"])})
    nas = build_nas(state, now)
    problems += nas["problems"]

    return {
        "nas": nas,
        "updater":_progress(progress, now) or _updater(state, now, has_errors=bool(problems)),
        "problems": problems,
        "apps": apps,
        "counts": {
            "installed": sum(1 for a in apps if a["installed"] and not a["isSelf"]),
            "attention": sum(1 for a in apps if a["status"]["kind"] == "error"),
            "updates": sum(1 for a in apps if a["status"]["kind"] == "update"),
            "shared": sum(1 for a in apps if a["shared"]),
            "nas": len(nas["problems"]),
        },
        "settings": {
            "defaultUpdates": default_mode,
            "accounts": [str(x) for x in (state.get("accounts") or []) if x],
        },
    }


def _progress(progress: Optional[dict], now: dt.datetime) -> Optional[dict]:
    """While a check runs: what it's doing. Ignored if not updated for 10 minutes (crashed run)."""
    if not isinstance(progress, dict) or not progress.get("running"):
        return None
    updated = _parse_utc(progress.get("updated"))
    if updated is None or now - updated > dt.timedelta(minutes=10):
        return None
    text = str(progress.get("text") or "Looking for updates")
    return {"kind": "busy", "title": "Checking now…", "sub": text.rstrip(".…") + "…"}


def _updater(state: dict, now: dt.datetime, has_errors: bool) -> dict:
    last = _parse_utc(state.get("lastRun"))
    if last is None:
        return {"kind": "none", "title": "Waiting for first check", "sub": "DevStore checks for updates every 5 minutes."}
    result = str(state.get("lastRunResult") or "")
    if result.startswith("failed"):
        return {"kind": "error", "title": "Updater problem", "sub": explain(result.partition(": ")[2] or result)}
    if now - last > STALE_AFTER:
        return {"kind": "warn", "title": "Not checked recently",
                "sub": f"Last check {ago(last, now)}. Is the PC asleep, or the DevStore Updater task turned off?"}
    if has_errors:
        return {"kind": "warn", "title": "Needs attention", "sub": f"Checked {ago(last, now)}"}
    return {"kind": "ok", "title": "Up to date", "sub": f"Checked {ago(last, now)}"}


def parse_activity(lines: list[str], limit: int = 200) -> list[dict]:
    """Updater log lines -> newest-first entries {time, app, text}."""
    out = []
    for line in lines:
        m = _LOG_RE.match(line.strip())
        if m:
            app = m.group(2)
            out.append({"time": m.group(1), "app": "" if app == "-" else app, "text": m.group(3)})
    return list(reversed(out))[:limit]


# ---------------------------------------------------------------- NAS (Docker apps)

NAS_STATUSES = ("ok", "pending", "stopped", "missing")


def _plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def _nas_header(configured: bool, error: str, failed: int, last_scan: Optional[dt.datetime], statuses: list,
                now: dt.datetime) -> dict:
    def h(kind: str, title: str, sub: str) -> dict:
        return {"kind": kind, "title": title, "sub": sub}

    if not configured:
        return h("none", "NAS status is off", "Add your Watchtower address in Settings → NAS to see what your NAS runs.")
    if error:
        low = error.lower()
        if "rejected the token" in low:
            return h("error", "Watchtower rejected the token", "Enter the token again in Settings → NAS.")
        if "no watchtower token" in low:
            return h("error", "No Watchtower token saved", "Enter it in Settings → NAS.")
        if "isn't turned on" in low:
            return h("error", "Watchtower's API is off", error)
        return h("error", "Can't reach the NAS", f"{error} Is the NAS on, and is this PC at home or on Tailscale?")
    sub = f"Watchtower checked {ago(last_scan, now)}" if last_scan else "Watchtower hasn't checked yet"
    if failed:
        return h("warn", f"Watchtower: {_plural(failed, 'update')} failed at its last check", sub)
    pending = statuses.count("pending")
    if pending:
        return h("ok", f"{_plural(pending, 'update')} waiting for Watchtower", sub)
    if statuses and all(x == "ok" for x in statuses):
        return h("ok", "NAS runs the latest versions", sub)
    return h("ok", "NAS status", sub)


def build_nas(state: Any, now: dt.datetime) -> dict:
    """Docker apps on the NAS, from the updater's state.nas: the newest version of each
    and, when Watchtower is set up, whether the NAS runs it."""
    nas = state.get("nas") if isinstance(state, dict) else None
    nas = nas if isinstance(nas, dict) else {}
    configured = bool(nas.get("url"))
    error = str(nas.get("error") or "") if configured else ""
    try:
        failed = int(nas.get("failed") or 0) if configured else 0
    except (TypeError, ValueError):
        failed = 0
    entries = nas.get("apps") if isinstance(nas.get("apps"), dict) else {}
    apps = []
    for repo, a in entries.items():
        if not isinstance(a, dict):
            continue
        latest = str(a.get("latest") or "?")
        status = a.get("status") if configured and not error and a.get("status") in NAS_STATUSES else "unknown"
        if not configured:
            kind, text = "none", f"Newest version {latest}"
        elif status == "ok":
            kind, text = "ok", f"Running the latest ({latest})"
        elif status == "pending":
            kind, text = "update", f"Update to {latest} waiting for Watchtower"
        elif status == "stopped":
            kind, text = "warn", "Stopped on the NAS"
        elif status == "missing":
            kind, text = "none", "Not running on the NAS"
        else:
            kind, text = "none", f"Unknown · newest is {latest}"
        apps.append({"repo": str(repo), "name": str(a.get("name") or str(repo).split("/")[-1]), "latest": latest,
                     "status": status, "kind": kind, "text": text})
    apps.sort(key=lambda x: x["name"].lower())
    header = _nas_header(configured, error, failed, _parse_utc(nas.get("lastScan")), [a["status"] for a in apps], now)
    problems = []
    if configured and (error or failed):
        problems.append({"repo": "", "title": header["title"], "detail": header["sub"]})
    problems += [{"repo": "", "title": f"{a['name']} is stopped on the NAS",
                  "detail": "Start it again in Container Manager on the NAS."} for a in apps if a["status"] == "stopped"]
    return {"configured": configured, "url": str(nas.get("url") or ""), "header": header, "apps": apps, "problems": problems}
