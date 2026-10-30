"""Pure logic for the DevStore Manager: reading updater files and turning
them into what the window shows. No tkinter, no Windows APIs, so it's unit-tested."""
from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

CHECK_INTERVAL_MINUTES = 10


@dataclass(frozen=True)
class AppRow:
    repo: str
    name: str
    display_name: str
    type: str
    installed: str
    latest: str
    status: str
    kind: str  # ok | pending | error | none (drives the row colour)
    last_checked: str
    error: str


def load_json(path: Path, default: dict) -> dict:
    """Missing, empty, corrupt or non-object JSON -> default. Accepts a UTF-8 BOM."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return default
    return data if isinstance(data, dict) else default


def service_name(name: str) -> str:
    return f"devstore-{name}"


def status_kind(app_state: Optional[dict]) -> str:
    if not app_state:
        return "none"
    status = app_state.get("status")
    if status in ("error", "rolledback"):
        return "error"
    if status == "pending":
        return "pending"
    return "ok" if status == "ok" else "none"


def status_text(app_state: Optional[dict], service_status: Optional[str]) -> str:
    if not app_state:
        return "Not installed yet"
    status = app_state.get("status")
    if status == "pending":
        return f"v{app_state.get('latest', '?')} waiting for app to close"
    if status == "rolledback":
        bad = app_state.get("bad") or ["?"]
        return f"v{bad[-1]} failed, rolled back"
    if status == "error":
        err = app_state.get("lastError")
        return f"Error: {err}" if err else "Error"
    if status == "ok":
        if app_state.get("restartPending"):
            return f"Updated to v{app_state.get('installed', '?')}, restart the app to use it"
        if app_state.get("type") == "service" and service_status:
            return f"Up to date, {service_status.lower()}"
        return "Up to date"
    return "Not installed yet"


def _app_states(state: dict) -> dict[str, dict]:
    apps = state.get("apps") if isinstance(state, dict) else None
    if not isinstance(apps, dict):
        return {}
    states = {}
    for k, v in apps.items():
        if isinstance(v, list):  # entries saved as [null, null, {...}] by updater 1.0.0
            v = next((x for x in reversed(v) if isinstance(x, dict)), None)
        if isinstance(v, dict):
            states[str(k).lower()] = v
    return states


def build_rows(config: dict, state: dict, services: dict[str, str], now: Optional[dt.datetime] = None) -> list[AppRow]:
    """One row per app in config.json, in config order. `services` maps
    service name (devstore-<name>) -> 'Running' / 'Stopped' / ..."""
    now = now or dt.datetime.now(dt.timezone.utc)
    entries = config.get("apps") if isinstance(config, dict) else None
    if not isinstance(entries, list):
        return []
    states = _app_states(state)
    rows = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("repo"):
            continue
        repo = str(entry["repo"])
        s = states.get(repo.lower())
        name = (s or {}).get("name") or repo.split("/")[-1]
        app_type = (s or {}).get("type") or ""
        svc = services.get(service_name(name)) if app_type == "service" else None
        rows.append(AppRow(
            repo=repo,
            name=name,
            display_name=(s or {}).get("displayName") or name,
            type={"gui": "App", "service": "Service"}.get(app_type, ""),
            installed=(s or {}).get("installed") or "",
            latest=(s or {}).get("latest") or "",
            status=status_text(s, svc),
            kind=status_kind(s),
            last_checked=format_time((s or {}).get("lastChecked"), now),
            error=(s or {}).get("lastError") or "",
        ))
    return rows


def _parse_utc(value: Any) -> Optional[dt.datetime]:
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def format_time(value: Any, now: dt.datetime) -> str:
    """UTC ISO timestamp -> local 'HH:MM' today, else 'Mon DD HH:MM'."""
    t = _parse_utc(value)
    if t is None:
        return "never"
    local, local_now = t.astimezone(), now.astimezone()
    if local.date() == local_now.date():
        return local.strftime("%H:%M")
    return local.strftime("%b %d %H:%M")


def footer_text(state: dict, now: dt.datetime) -> str:
    last = _parse_utc(state.get("lastRun")) if isinstance(state, dict) else None
    if last is None:
        return f"The updater hasn't run yet. It runs every {CHECK_INTERVAL_MINUTES} minutes, or press Check now."
    result = state.get("lastRunResult") or "unknown"
    summary = "all good" if result == "ok" else result
    return (f"Last check {format_time(state.get('lastRun'), now)}: {summary}. "
            f"Next check within {CHECK_INTERVAL_MINUTES} minutes.")


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


def filter_log(lines: list[str], name: str, limit: int = 50) -> list[str]:
    tag = f"[{name}]"
    return [line for line in lines if tag in line][-limit:]
