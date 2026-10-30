"""DevStoreSetup.exe: installs or upgrades the DevStore Updater on this PC.

Built with PyInstaller --onefile --uac-admin, so Windows asks for admin once
when it starts. It runs the bundled Install-DevStoreAgent.ps1 and shows its
output."""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk

from devstore_setup import logic

COLOR_ERROR = "#b3261e"
COLOR_OK = "#1e6b35"
COLOR_MUTED = "#5f6368"
_CREATE_NO_WINDOW = 0x08000000


def _version() -> str:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))
    try:
        return (base / "version.txt").read_text(encoding="utf-8").strip()
    except OSError:
        return "dev"


class SetupWindow(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("DevStore Setup")
        self.geometry("640x560")
        self.minsize(540, 500)
        style = ttk.Style(self)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        self.option_add("*Font", ("Segoe UI", 9))
        style.configure("Title.TLabel", font=("Segoe UI", 13, "bold"))
        style.configure("Muted.TLabel", foreground=COLOR_MUTED)
        style.configure("Error.TLabel", foreground=COLOR_ERROR)
        style.configure("Ok.TLabel", foreground=COLOR_OK)

        self.installed = logic.is_installed()
        body = ttk.Frame(self, padding=(20, 18, 20, 16))
        body.pack(fill="both", expand=True)

        ttk.Label(body, text="Install DevStore on this PC" if not self.installed else "Update DevStore on this PC",
                  style="Title.TLabel").pack(anchor="w")
        ttk.Label(body, wraplength=560, justify="left", text=(
            "DevStore keeps your apps on this PC up to date from GitHub, and adds the "
            "DevStore Manager window to the Start menu.")).pack(anchor="w", pady=(6, 14))

        ttk.Label(body, text="GitHub token").pack(anchor="w")
        self.token_var = tk.StringVar()
        self.token_entry = ttk.Entry(body, textvariable=self.token_var, show="•", width=70)
        self.token_entry.pack(fill="x", pady=(4, 4))
        self.token_entry.bind("<Return>", lambda _e: self.on_install())
        hint = ("A fine-grained token with read-only \"Contents\" access to your repos "
                "(github.com → Settings → Developer settings → Fine-grained tokens).")
        if self.installed:
            hint += " DevStore is already installed: leave this empty to keep the current token."
        ttk.Label(body, text=hint, style="Muted.TLabel", wraplength=560, justify="left").pack(anchor="w")
        self.add_var = tk.BooleanVar(value=False)
        if self.installed:
            ttk.Checkbutton(body, variable=self.add_var, text=(
                "Add as another GitHub account (for apps in someone else's repos, "
                "using a token they created for you)")).pack(anchor="w", pady=(8, 0))
        ttk.Label(body, style="Muted.TLabel", wraplength=560, justify="left", text=(
            f"Apps install to {logic.ROOT}\\apps. Their data stays in C:\\ProgramData\\<app name>, "
            "and is kept if an app is removed.")).pack(anchor="w", pady=(10, 0))

        row = ttk.Frame(body)
        row.pack(fill="x", pady=(14, 8))
        self.install_btn = ttk.Button(row, text="Install" if not self.installed else "Update",
                                      command=self.on_install, default="active")
        self.install_btn.pack(side="left")
        self.status = ttk.Label(row, text="", wraplength=440, justify="left")
        self.status.pack(side="left", padx=(12, 0))

        self.log = tk.Text(body, height=10, wrap="word", font=("Consolas", 9), relief="solid", borderwidth=1,
                           background="#fbfbfb", foreground="#202124", padx=8, pady=6, state="disabled")
        self.log.pack(fill="both", expand=True)
        ttk.Label(body, text=f"v{_version()}", style="Muted.TLabel").pack(anchor="e", pady=(6, 0))
        self.token_entry.focus_set()

    def _append(self, line: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", line + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def on_install(self) -> None:
        if str(self.install_btn["state"]) == "disabled":
            return
        token = self.token_var.get()
        add = bool(self.add_var.get())
        error = logic.validate_token(token, self.installed, add)
        if error:
            self.status.configure(text=error, style="Error.TLabel")
            self.token_entry.focus_set()
            return
        self.install_btn.state(["disabled"])
        self.token_entry.state(["disabled"])
        self.status.configure(text="Installing… this takes about a minute.", style="TLabel")
        threading.Thread(target=self._run, args=(token, add), daemon=True).start()

    def _run(self, token: str, add: bool = False) -> None:
        lines: list[str] = []
        try:
            proc = subprocess.Popen(
                logic.install_command(logic.payload_dir()), env=logic.child_env(os.environ, token, add),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                text=True, errors="replace", creationflags=_CREATE_NO_WINDOW)
            assert proc.stdout is not None
            for raw in proc.stdout:
                line = raw.rstrip()
                lines.append(line)
                self.after(0, self._append, line)
            code = proc.wait()
        except OSError as e:
            lines.append(str(e))
            code = 1
        self.after(0, self._done, *logic.summarize(code, lines))

    def _done(self, ok: bool, message: str) -> None:
        self.status.configure(text=message, style="Ok.TLabel" if ok else "Error.TLabel")
        if ok:
            self.install_btn.configure(text="Close", command=self.destroy)
            self.install_btn.state(["!disabled"])
        else:
            self.install_btn.state(["!disabled"])
            self.token_entry.state(["!disabled"])


def main() -> None:
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass
    SetupWindow().mainloop()


if __name__ == "__main__":
    main()
