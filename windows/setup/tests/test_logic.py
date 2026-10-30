from pathlib import Path

from devstore_setup import logic


def test_validate_token():
    assert logic.validate_token("", already_installed=False) == "Paste your GitHub token first."
    assert logic.validate_token("   ", already_installed=True) is None  # keep the stored token
    assert logic.validate_token("github_pat_abc DEF", already_installed=False) == "The token can't contain spaces."
    assert "github_pat_" in logic.validate_token("hello", already_installed=False)
    assert logic.validate_token("  github_pat_11ABC  ", already_installed=False) is None
    assert logic.validate_token("ghp_abc123", already_installed=False) is None


def test_install_command_is_non_interactive():
    cmd = logic.install_command(Path("C:/x/agent"))
    assert cmd[0] == "powershell.exe"
    assert "-NonInteractive" in cmd and "-NoProfile" in cmd
    assert cmd[-1].endswith("Install-DevStoreAgent.ps1")
    assert cmd[cmd.index("-ExecutionPolicy") + 1] == "Bypass"


def test_child_env_passes_token_only_via_environment():
    env = logic.child_env({"PATH": "p", "DEVSTORE_TOKEN": "old"}, "  github_pat_new ")
    assert env["DEVSTORE_TOKEN"] == "github_pat_new"
    assert env["PATH"] == "p"
    kept = logic.child_env({"PATH": "p", "DEVSTORE_TOKEN": "old"}, "")
    assert "DEVSTORE_TOKEN" not in kept


def test_is_installed(tmp_path):
    assert not logic.is_installed(tmp_path)
    (tmp_path / "token.dat").write_text("x")
    assert logic.is_installed(tmp_path)


def test_summarize():
    ok, msg = logic.summarize(0, ["a", "Done. The updater is running its first pass now."])
    assert ok and "Start menu" in msg
    ok, msg = logic.summarize(1, ["Checking the token...", "GitHub token rejected (HTTP 401).", ""])
    assert not ok and msg == "Setup failed: GitHub token rejected (HTTP 401)."
    ok, msg = logic.summarize(1, [])
    assert not ok and msg.startswith("Setup failed")


def test_payload_dir_in_development():
    assert (logic.payload_dir() / "Install-DevStoreAgent.ps1").exists()
