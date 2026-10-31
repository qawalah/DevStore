from pathlib import Path

import sys

import pytest

from devstore_manager import actions


@pytest.fixture
def calls(monkeypatch):
    recorded = []

    def fake(file, params):
        recorded.append((file, params))
        return 0

    monkeypatch.setattr(actions, "_shell_execute_wait", fake)
    return recorded


def test_elevated_args_quotes_script_and_params():
    args = actions.elevated_args("Add-DevStoreApp.ps1", Repo="qawalah/my-app")
    script = str(actions.AGENT_DIR / "Add-DevStoreApp.ps1")
    assert args == f'-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{script}" -Repo "qawalah/my-app"'


def test_elevated_args_rejects_unsafe_values():
    for bad in ['a/b" -X', "a/b; calc", "a b/c", ""]:
        with pytest.raises(ValueError):
            actions.elevated_args("Add-DevStoreApp.ps1", Repo=bad)


def test_service_actions(calls):
    actions.service_action("my-svc", "Restart")
    assert '-Name "my-svc" -Action "Restart"' in calls[-1][1]
    with pytest.raises(ValueError):
        actions.service_action("my-svc", "Delete")


def test_run_elevated_raises_on_failure_and_cancel(monkeypatch):
    monkeypatch.setattr(actions, "_shell_execute_wait", lambda f, p: 1)
    with pytest.raises(actions.ActionFailed):
        actions.run_elevated("Start-DevStoreCheck.ps1")

    def cancelled(f, p):
        raise actions.Cancelled()

    monkeypatch.setattr(actions, "_shell_execute_wait", cancelled)
    with pytest.raises(actions.Cancelled):
        actions.run_elevated("Start-DevStoreCheck.ps1")


def test_parse_sc_query():
    out = """
SERVICE_NAME: devstore-x
        TYPE               : 10  WIN32_OWN_PROCESS
        STATE              : 4  RUNNING
                                (STOPPABLE, NOT_PAUSABLE, ACCEPTS_SHUTDOWN)
"""
    assert actions.parse_sc_state(out) == "Running"
    assert actions.parse_sc_state("        STATE              : 1  STOPPED") == "Stopped"
    assert actions.parse_sc_state("        STATE              : 2  START_PENDING") == "Starting"
    assert actions.parse_sc_state("[SC] EnumQueryServicesStatus:OpenService FAILED 1060") is None


def test_app_paths():
    assert actions.app_exe("hello", "hello.exe") == actions.ROOT / "apps" / "hello" / "current" / "hello.exe"
    assert actions.data_dir("hello").name == "hello"
    assert isinstance(actions.data_dir("hello"), Path)


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setattr(actions, "ROOT", tmp_path)
    (tmp_path / "requests").mkdir()
    return tmp_path


def test_install_and_remove_write_requests_and_start_updater(root, monkeypatch):
    started = []
    monkeypatch.setattr(actions, "start_updater", lambda: started.append(1) or True)
    actions.install("  qawalah/Tool ")
    actions.remove("qawalah/old")
    assert actions.pending_requests() == {"qawalah/Tool": "install", "qawalah/old": "remove"}
    assert len(started) == 2
    with pytest.raises(ValueError):
        actions.install("not a repo")


def test_pending_requests_ignores_junk(root):
    (root / "requests" / "x.json").write_text("not json")
    (root / "requests" / "y.json").write_text('{"action": "check"}')
    assert actions.pending_requests() == {}


def test_check_now_falls_back_to_admin_prompt(root, monkeypatch):
    calls = []
    monkeypatch.setattr(actions, "start_updater", lambda: False)
    monkeypatch.setattr(actions, "_shell_execute_wait", lambda f, p: calls.append(p) or 0)
    actions.check_now()
    assert "Start-DevStoreCheck.ps1" in calls[0]
    monkeypatch.setattr(actions, "start_updater", lambda: True)
    actions.check_now()
    assert len(calls) == 1


def test_apps_from_process_paths(tmp_path, monkeypatch):
    monkeypatch.setattr(actions, "ROOT", tmp_path)
    procs = [(1, str(tmp_path / "apps" / "tool" / "current" / "tool.exe")),
             (2, str(tmp_path / "APPS" / "Tool" / "versions" / "1.0.0" / "helper.exe")),
             (3, str(tmp_path / "apps" / "other" / "current" / "other.exe")),
             (4, r"C:\Windows\explorer.exe"), (5, "")]
    assert actions.apps_from_processes(procs) == {"tool", "other"}
    assert actions.pids_for_app(procs, "tool") == [1, 2]
    assert actions.pids_for_app(procs, "missing") == []


@pytest.mark.skipif(sys.platform != "win32", reason="needs real Windows processes")
def test_force_close_a_real_running_app(tmp_path, monkeypatch):
    # A copy of ping.exe stands in for an installed app.
    import shutil
    import subprocess
    import time
    monkeypatch.setattr(actions, "ROOT", tmp_path)
    exe = tmp_path / "apps" / "pinger" / "current" / "pinger.exe"
    exe.parent.mkdir(parents=True)
    shutil.copy(r"C:\Windows\System32\PING.EXE", exe)
    p = subprocess.Popen([str(exe), "-n", "60", "127.0.0.1"], stdout=subprocess.DEVNULL)
    try:
        time.sleep(1)
        assert "pinger" in actions.running_apps()
        assert actions.close_app("pinger") >= 1
        p.wait(timeout=10)
        assert "pinger" not in actions.running_apps()
    finally:
        if p.poll() is None:
            p.kill()


def test_apply_update_and_set_update_modes(root, monkeypatch):
    import json
    monkeypatch.setattr(actions, "start_updater", lambda: True)
    actions.apply_update("qawalah/t")
    actions.set_updates("qawalah/t", "notify")
    actions.set_updates(None, "download")
    bodies = [json.loads(f.read_text()) for f in sorted((root / "requests").glob("*.json"))]
    assert {"action": "apply", "repo": "qawalah/t"} in bodies
    assert {"action": "set-updates", "repo": "qawalah/t", "mode": "notify"} in bodies
    assert {"action": "set-updates", "mode": "download"} in bodies
    with pytest.raises(ValueError):
        actions.set_updates("qawalah/t", "sometimes")
    with pytest.raises(ValueError):
        actions.set_updates(None, "default")


def test_set_channel_writes_request(root, monkeypatch):
    import json
    monkeypatch.setattr(actions, "start_updater", lambda: True)
    actions.set_channel("qawalah/t", "pr-12")
    actions.set_channel("qawalah/t", "stable")
    bodies = [json.loads(f.read_text()) for f in sorted((root / "requests").glob("*.json"))]
    assert {"action": "set-channel", "repo": "qawalah/t", "channel": "pr-12"} in bodies
    assert {"action": "set-channel", "repo": "qawalah/t", "channel": "stable"} in bodies
    with pytest.raises(ValueError):
        actions.set_channel("qawalah/t", "pr-x")
