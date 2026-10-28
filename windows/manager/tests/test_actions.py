from pathlib import Path

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


def test_add_app_validates_and_runs_elevated(calls):
    actions.add_app("  qawalah/my-app  ")
    file, params = calls[-1]
    assert file == "powershell.exe"
    assert "Add-DevStoreApp.ps1" in params and '-Repo "qawalah/my-app"' in params
    with pytest.raises(ValueError):
        actions.add_app("not-a-repo")


def test_remove_check_and_service_actions(calls):
    actions.remove_app("qawalah/x")
    assert "Remove-DevStoreApp.ps1" in calls[-1][1]
    actions.check_now()
    assert "Start-DevStoreCheck.ps1" in calls[-1][1]
    actions.service_action("my-svc", "Restart")
    assert '-Name "my-svc" -Action "Restart"' in calls[-1][1]
    with pytest.raises(ValueError):
        actions.service_action("my-svc", "Delete")


def test_run_elevated_raises_on_failure_and_cancel(monkeypatch):
    monkeypatch.setattr(actions, "_shell_execute_wait", lambda f, p: 1)
    with pytest.raises(actions.ActionFailed):
        actions.check_now()

    def cancelled(f, p):
        raise actions.Cancelled()

    monkeypatch.setattr(actions, "_shell_execute_wait", cancelled)
    with pytest.raises(actions.Cancelled):
        actions.check_now()


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
