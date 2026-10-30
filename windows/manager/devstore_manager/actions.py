"""Things the DevStore Manager does to the system.

Installing, removing and checking need no admin rights: the Manager drops a
request file in C:\\DevStore\\requests and starts the "DevStore Updater" task,
which applies it as SYSTEM. Service start/stop still asks for admin (UAC)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(os.environ.get("DEVSTORE_ROOT", r"C:\DevStore"))
AGENT_DIR = ROOT / "agent"
LOG_DIR = ROOT / "logs"

REPO_RE = re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$")
NAME_RE = re.compile(r"^[a-z0-9-]+$")
SERVICE_ACTIONS = ("Start", "Stop", "Restart")
_SAFE_VALUE = re.compile(r"^[A-Za-z0-9._/-]+$")
_CREATE_NO_WINDOW = 0x08000000


class Cancelled(Exception):
    """The user said no to the Windows admin (UAC) prompt."""


class ActionFailed(Exception):
    pass


def elevated_args(script: str, **params: str) -> str:
    """Command line for powershell.exe running an agent script with -Name "value" params."""
    parts = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
             "-File", f'"{AGENT_DIR / script}"']
    for key, value in params.items():
        if not _SAFE_VALUE.match(value or "") or ".." in value:
            raise ValueError(f"Unsafe value for -{key}: {value!r}")
        parts.append(f'-{key} "{value}"')
    return " ".join(parts)


def _shell_execute_wait(file: str, params: str) -> int:
    """ShellExecuteEx with the 'runas' verb (UAC prompt); waits and returns the exit code."""
    import ctypes
    from ctypes import wintypes

    class SHELLEXECUTEINFOW(ctypes.Structure):
        _fields_ = [
            ("cbSize", wintypes.DWORD), ("fMask", ctypes.c_ulong), ("hwnd", wintypes.HWND),
            ("lpVerb", wintypes.LPCWSTR), ("lpFile", wintypes.LPCWSTR), ("lpParameters", wintypes.LPCWSTR),
            ("lpDirectory", wintypes.LPCWSTR), ("nShow", ctypes.c_int), ("hInstApp", wintypes.HINSTANCE),
            ("lpIDList", ctypes.c_void_p), ("lpClass", wintypes.LPCWSTR), ("hkeyClass", wintypes.HKEY),
            ("dwHotKey", wintypes.DWORD), ("hIconOrMonitor", wintypes.HANDLE), ("hProcess", wintypes.HANDLE),
        ]

    SEE_MASK_NOCLOSEPROCESS, SW_HIDE, ERROR_CANCELLED, INFINITE = 0x40, 0, 1223, 0xFFFFFFFF
    info = SHELLEXECUTEINFOW(cbSize=ctypes.sizeof(SHELLEXECUTEINFOW), fMask=SEE_MASK_NOCLOSEPROCESS,
                             lpVerb="runas", lpFile=file, lpParameters=params, nShow=SW_HIDE)
    shell32, kernel32 = ctypes.windll.shell32, ctypes.windll.kernel32
    if not shell32.ShellExecuteExW(ctypes.byref(info)):
        if ctypes.GetLastError() == ERROR_CANCELLED:
            raise Cancelled()
        raise ActionFailed(f"Couldn't start PowerShell (error {ctypes.GetLastError()}).")
    try:
        kernel32.WaitForSingleObject(info.hProcess, INFINITE)
        code = wintypes.DWORD()
        kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
        return code.value
    finally:
        kernel32.CloseHandle(info.hProcess)


def run_elevated(script: str, **params: str) -> None:
    code = _shell_execute_wait("powershell.exe", elevated_args(script, **params))
    if code != 0:
        raise ActionFailed(f"{script} failed (exit code {code}). Details are in {LOG_DIR}.")


TASK_NAME = "DevStore Updater"


def start_updater() -> bool:
    """Starts the updater task now. Normal users may do this (the updater grants it)."""
    try:
        r = subprocess.run(["schtasks.exe", "/run", "/tn", TASK_NAME], capture_output=True, text=True,
                           timeout=15, creationflags=_CREATE_NO_WINDOW)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _write_request(action: str, repo: str | None = None) -> None:
    folder = ROOT / "requests"
    body = {"action": action} if repo is None else {"action": action, "repo": repo}
    name = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"
    tmp = folder / f"{name}.tmp"
    tmp.write_text(json.dumps(body), encoding="utf-8")
    tmp.replace(folder / f"{name}.json")  # the updater only reads *.json, never half-written files


def pending_requests() -> dict[str, str]:
    """repo -> 'install'/'remove' for requests the updater hasn't applied yet."""
    out: dict[str, str] = {}
    try:
        files = sorted((ROOT / "requests").glob("*.json"))
    except OSError:
        return out
    for f in files:
        try:
            body = json.loads(f.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if isinstance(body, dict) and body.get("action") in ("install", "remove") and REPO_RE.match(str(body.get("repo", ""))):
            out[body["repo"]] = body["action"]
    return out


def install(repo: str) -> None:
    repo = repo.strip()
    if not REPO_RE.match(repo):
        raise ValueError("Enter the repo as owner/name, for example qawalah/my-app.")
    _write_request("install", repo)
    start_updater()


def remove(repo: str) -> None:
    if not REPO_RE.match(repo):
        raise ValueError(f"Can't remove {repo!r}.")
    _write_request("remove", repo)
    start_updater()


def check_now() -> None:
    if not start_updater():
        run_elevated("Start-DevStoreCheck.ps1")  # older install: the task isn't startable without admin yet


def service_action(name: str, action: str) -> None:
    if action not in SERVICE_ACTIONS or not NAME_RE.match(name):
        raise ValueError(f"Can't {action} {name}.")
    run_elevated("Invoke-DevStoreServiceAction.ps1", Name=name, Action=action)


def app_exe(name: str, exe: str) -> Path:
    return ROOT / "apps" / name / "current" / exe


def data_dir(name: str) -> Path:
    return Path(os.environ.get("ProgramData", r"C:\ProgramData")) / name


def launch(path: Path) -> None:
    os.startfile(str(path))  # type: ignore[attr-defined]  # Windows only


def open_folder(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.startfile(str(path))  # type: ignore[attr-defined]


_SC_STATES = {"RUNNING": "Running", "STOPPED": "Stopped", "START_PENDING": "Starting",
              "STOP_PENDING": "Stopping", "PAUSED": "Paused"}


def parse_sc_state(output: str):
    m = re.search(r"STATE\s*:\s*\d+\s+(\w+)", output)
    return _SC_STATES.get(m.group(1), m.group(1).title()) if m else None


def service_statuses(names: list[str]) -> dict[str, str]:
    """{'devstore-x': 'Running', ...} for services that exist. Readable without admin."""
    result = {}
    if sys.platform != "win32":
        return result
    for svc in names:
        try:
            out = subprocess.run(["sc.exe", "query", svc], capture_output=True, text=True,
                                 timeout=5, creationflags=_CREATE_NO_WINDOW).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        state = parse_sc_state(out)
        if state:
            result[svc] = state
    return result
