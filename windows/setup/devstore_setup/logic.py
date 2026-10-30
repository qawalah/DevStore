"""Pure logic for DevStoreSetup.exe, kept separate from the window so it's unit-tested."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional

ROOT = Path(r"C:\DevStore")
TOKEN_PREFIXES = ("github_pat_", "ghp_")


def validate_token(token: str, already_installed: bool, add_account: bool = False) -> Optional[str]:
    """None if OK; otherwise a message for the user. Empty is OK only when a token is already stored."""
    t = token.strip()
    if not t:
        if add_account:
            return "Paste the other account's token first."
        return None if already_installed else "Paste your GitHub token first."
    if any(c.isspace() for c in t):
        return "The token can't contain spaces."
    if not t.startswith(TOKEN_PREFIXES):
        return "That doesn't look like a GitHub token. It should start with github_pat_."
    return None


def payload_dir() -> Path:
    """Folder holding Install-DevStoreAgent.ps1 and the other agent scripts."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "agent"  # type: ignore[attr-defined]
    return Path(__file__).resolve().parents[2] / "agent"


def install_command(script_dir: Path) -> list[str]:
    # -NonInteractive: if anything would prompt, fail with a message instead of hanging invisibly.
    return ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(script_dir / "Install-DevStoreAgent.ps1")]


def child_env(base: dict, token: str, add_account: bool = False) -> dict:
    """The token goes to the install script through the environment, never the command line."""
    env = dict(base)
    env.pop("DEVSTORE_TOKEN", None)
    env.pop("DEVSTORE_TOKEN_MODE", None)
    if token.strip():
        env["DEVSTORE_TOKEN"] = token.strip()
        if add_account:
            env["DEVSTORE_TOKEN_MODE"] = "add"
    return env


def is_installed(root: Path = ROOT) -> bool:
    return (Path(root) / "token.dat").exists()


def summarize(exit_code: int, lines: list[str]) -> tuple[bool, str]:
    if exit_code == 0:
        return True, ("Done. DevStore Manager appears in the Start menu (DevStore folder) "
                      "within a few minutes. You can close this window.")
    last = next((line.strip() for line in reversed(lines) if line.strip()), "")
    return False, f"Setup failed: {last}" if last else f"Setup failed (exit code {exit_code})."
