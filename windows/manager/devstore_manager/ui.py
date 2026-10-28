"""DevStore Manager window (tkinter/ttk). Widgets only: data comes from
model.py, system changes go through actions.py."""
from __future__ import annotations

import datetime as dt
import json
import sys
import threading
import tkinter as tk
from tkinter import messagebox, ttk
from typing import Callable, Optional

from . import actions, model

REFRESH_MS = 15_000
COLUMNS = (
    ("app", "App", 200, "w"),
    ("type", "Type", 70, "w"),
    ("installed", "Installed", 80, "w"),
    ("latest", "Available", 80, "w"),
    ("status", "Status", 260, "w"),
    ("checked", "Last checked", 100, "w"),
)
# Restrained palette: colour only marks states that need attention.
COLOR_ERROR = "#b3261e"
COLOR_PENDING = "#8a5a00"
COLOR_MUTED = "#5f6368"


def _app_version() -> str:
    from pathlib import Path
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent.parent
    try:
        return json.loads((base / "devstore.json").read_text(encoding="utf-8"))["version"]
    except (OSError, ValueError, KeyError):
        return "dev"


class ManagerWindow(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("DevStore Manager")
        self.geometry("880x600")
        self.minsize(720, 460)
        self._rows: dict[str, model.AppRow] = {}
        self._states: dict[str, dict] = {}
        self._busy = False
        self._services: dict[str, str] = {}

        style = ttk.Style(self)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        base = ("Segoe UI", 9)
        style.configure("Title.TLabel", font=("Segoe UI", 11, "bold"))
        field_bg = style.lookup("Treeview", "fieldbackground") or "white"
        style.configure("Empty.TLabel", foreground=COLOR_MUTED, background=field_bg)
        style.configure("Muted.TLabel", foreground=COLOR_MUTED)
        style.configure("Error.TLabel", foreground=COLOR_ERROR)
        style.configure("Treeview", rowheight=24)
        self.option_add("*Font", base)

        self._build_toolbar()
        self._build_table()
        self._build_details()
        self._build_statusbar()

        self.bind("<F5>", lambda _e: self.refresh())
        self.refresh()
        self.after(REFRESH_MS, self._auto_refresh)

    # ------------------------------------------------------------ layout

    def _build_toolbar(self) -> None:
        bar = ttk.Frame(self, padding=(12, 10, 12, 6))
        bar.pack(fill="x")
        self.check_btn = ttk.Button(bar, text="Check now", command=self.on_check_now, default="active")
        self.check_btn.pack(side="left")

        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=12)
        ttk.Label(bar, text="Add app (GitHub owner/name):").pack(side="left")
        self.repo_var = tk.StringVar()
        self.repo_entry = ttk.Entry(bar, textvariable=self.repo_var, width=30)
        self.repo_entry.pack(side="left", padx=(6, 6))
        self.repo_entry.bind("<Return>", lambda _e: self.on_add())
        self.add_btn = ttk.Button(bar, text="Add", command=self.on_add)
        self.add_btn.pack(side="left")

        self.refresh_btn = ttk.Button(bar, text="Refresh", command=self.refresh)
        self.refresh_btn.pack(side="right")

    def _build_table(self) -> None:
        holder = ttk.Frame(self, padding=(12, 0, 12, 0))
        holder.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(holder, columns=[c[0] for c in COLUMNS], show="headings", selectmode="browse", height=8)
        for key, title, width, anchor in COLUMNS:
            self.tree.heading(key, text=title, anchor=anchor)
            self.tree.column(key, width=width, anchor=anchor, stretch=(key == "status"))
        self.tree.tag_configure("error", foreground=COLOR_ERROR)
        self.tree.tag_configure("pending", foreground=COLOR_PENDING)
        self.tree.tag_configure("none", foreground=COLOR_MUTED)
        scroll = ttk.Scrollbar(holder, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")
        self.tree.bind("<<TreeviewSelect>>", lambda _e: self._show_details())
        self.tree.bind("<Double-1>", lambda _e: self.on_launch())

        self.empty_label = ttk.Label(
            self.tree, style="Empty.TLabel", justify="center",
            text="No apps yet.\n\nType a repo such as qawalah/my-app above and press Add.\n"
                 "It installs on this PC within a few minutes, then keeps itself up to date.")

    def _build_details(self) -> None:
        box = ttk.Frame(self, padding=(12, 12, 12, 0))
        box.pack(fill="x")
        head = ttk.Frame(box)
        head.pack(fill="x")
        self.title_label = ttk.Label(head, text="Select an app", style="Title.TLabel")
        self.title_label.pack(side="left")
        self.repo_label = ttk.Label(head, text="", style="Muted.TLabel")
        self.repo_label.pack(side="left", padx=(8, 0))

        self.error_label = ttk.Label(box, text="", style="Error.TLabel", wraplength=840, justify="left")
        self.error_label.pack(fill="x", pady=(4, 0))

        buttons = ttk.Frame(box)
        buttons.pack(fill="x", pady=(8, 0))
        self.launch_btn = ttk.Button(buttons, text="Open app", command=self.on_launch)
        self.start_btn = ttk.Button(buttons, text="Start", command=lambda: self.on_service("Start"))
        self.stop_btn = ttk.Button(buttons, text="Stop", command=lambda: self.on_service("Stop"))
        self.restart_btn = ttk.Button(buttons, text="Restart", command=lambda: self.on_service("Restart"))
        self.data_btn = ttk.Button(buttons, text="Open data folder", command=self.on_open_data)
        for b in (self.launch_btn, self.start_btn, self.stop_btn, self.restart_btn, self.data_btn):
            b.pack(side="left", padx=(0, 6))
        self.remove_btn = ttk.Button(buttons, text="Remove…", command=self.on_remove)
        self.remove_btn.pack(side="right")

        ttk.Label(box, text="Activity", style="Muted.TLabel").pack(anchor="w", pady=(12, 2))
        logframe = ttk.Frame(box)
        logframe.pack(fill="both", expand=True)
        self.log = tk.Text(logframe, height=9, wrap="none", font=("Consolas", 9), relief="solid", borderwidth=1,
                           background="#fbfbfb", foreground="#202124", padx=8, pady=6,
                           selectbackground="#cde3fb", selectforeground="#202124", state="disabled")
        logscroll = ttk.Scrollbar(logframe, orient="vertical", command=self.log.yview)
        self.log.configure(yscrollcommand=logscroll.set)
        self.log.pack(side="left", fill="both", expand=True)
        logscroll.pack(side="left", fill="y")

    def _build_statusbar(self) -> None:
        ttk.Separator(self).pack(fill="x", pady=(12, 0))
        bar = ttk.Frame(self, padding=(12, 6))
        bar.pack(fill="x")
        self.footer_label = ttk.Label(bar, text="", style="Muted.TLabel")
        self.footer_label.pack(side="left")
        self.busy_label = ttk.Label(bar, text="")
        self.busy_label.pack(side="right")
        ttk.Label(bar, text=f"v{_app_version()}", style="Muted.TLabel").pack(side="right", padx=(0, 12))

    # ------------------------------------------------------------ data

    def refresh(self) -> None:
        if not actions.ROOT.exists():
            self._render([], {})
            self.footer_label.configure(
                text=f"The DevStore Updater isn't installed on this PC ({actions.ROOT} not found). "
                     "Run Install-DevStoreAgent.ps1 as administrator.")
            return
        config = model.load_json(actions.ROOT / "config.json", {})
        state = model.load_json(actions.ROOT / "state.json", {})
        self._states = {str(k).lower(): v for k, v in (state.get("apps") or {}).items() if isinstance(v, dict)}
        rows = model.build_rows(config, state, self._services)
        self._render(rows, state)
        self._refresh_services([r.name for r in rows if r.type == "Service"])

    def _refresh_services(self, names: list[str]) -> None:
        if not names:
            return

        def work() -> None:
            statuses = actions.service_statuses([model.service_name(n) for n in names])
            self.after(0, lambda: self._apply_services(statuses))

        threading.Thread(target=work, daemon=True).start()

    def _apply_services(self, statuses: dict[str, str]) -> None:
        if statuses != self._services:
            self._services = statuses
            self.refresh()

    def _render(self, rows: list[model.AppRow], state: dict) -> None:
        selected = self._selected_repo()
        self._rows = {r.repo: r for r in rows}
        self.tree.delete(*self.tree.get_children())
        for r in rows:
            self.tree.insert("", "end", iid=r.repo, tags=(r.kind,),
                             values=(r.display_name, r.type, r.installed or "–", r.latest or "–", r.status, r.last_checked))
        if rows:
            self.empty_label.place_forget()
        else:
            self.empty_label.place(relx=0.5, rely=0.5, anchor="center")
        if selected in self._rows:
            self.tree.selection_set(selected)
        elif rows and not selected:
            self.tree.selection_set(rows[0].repo)
        self.footer_label.configure(text=model.footer_text(state, dt.datetime.now(dt.timezone.utc)))
        self._show_details()

    def _selected_repo(self) -> Optional[str]:
        sel = self.tree.selection()
        return sel[0] if sel else None

    def _selected(self) -> Optional[model.AppRow]:
        repo = self._selected_repo()
        return self._rows.get(repo) if repo else None

    def _show_details(self) -> None:
        row = self._selected()
        if row is None:
            self.title_label.configure(text="Select an app" if self._rows else "")
            self.repo_label.configure(text="")
            self.error_label.configure(text="")
            self._set_log([])
        else:
            self.title_label.configure(text=row.display_name)
            self.repo_label.configure(text=row.repo)
            self.error_label.configure(text=row.error if row.kind == "error" else "")
            lines = model.filter_log(model.read_log_lines(actions.LOG_DIR), row.name)
            self._set_log(lines or ["No activity for this app yet."])
        self._update_buttons()

    def _set_log(self, lines: list[str]) -> None:
        if lines == getattr(self, "_log_lines", None):
            return  # unchanged: keep the user's scroll position
        self._log_lines = lines
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.insert("end", "\n".join(lines))
        self.log.see("end")
        self.log.configure(state="disabled")

    def _update_buttons(self) -> None:
        row = self._selected()
        installed = bool(row and row.installed)
        svc = self._services.get(model.service_name(row.name)) if row else None

        def state(enabled: bool) -> list[str]:
            return ["!disabled"] if enabled and not self._busy else ["disabled"]

        self.check_btn.state(state(True))
        self.add_btn.state(state(True))
        self.launch_btn.state(state(installed and row.type == "App"))
        self.start_btn.state(state(installed and row.type == "Service" and svc != "Running"))
        self.stop_btn.state(state(installed and row.type == "Service" and svc == "Running"))
        self.restart_btn.state(state(installed and row.type == "Service"))
        self.data_btn.state(state(row is not None))
        self.remove_btn.state(state(row is not None))

    def _auto_refresh(self) -> None:
        if not self._busy:
            self.refresh()
        self.after(REFRESH_MS, self._auto_refresh)

    # ------------------------------------------------------------ actions

    def _run(self, label: str, fn: Callable[[], None], done: str) -> None:
        """Runs an elevated action off the UI thread, with inline progress and errors."""
        if self._busy:
            return
        self._busy = True
        self.busy_label.configure(text=f"{label} Approve the Windows admin prompt to continue.", style="TLabel")
        self._update_buttons()

        def work() -> None:
            try:
                fn()
                result = (done, "TLabel")
            except actions.Cancelled:
                result = ("Cancelled: admin approval was declined.", "Muted.TLabel")
            except (actions.ActionFailed, ValueError, OSError) as e:
                result = (str(e), "Error.TLabel")
            self.after(0, lambda: self._finish(*result))

        threading.Thread(target=work, daemon=True).start()

    def _finish(self, message: str, style: str) -> None:
        self._busy = False
        self.busy_label.configure(text=message, style=style)
        self.refresh()

    def on_check_now(self) -> None:
        self._run("Starting a check…", actions.check_now,
                  "Check started. Results appear here within a minute.")

    def on_add(self) -> None:
        repo = self.repo_var.get().strip()
        if not actions.REPO_RE.match(repo):
            self.busy_label.configure(text="Enter the repo as owner/name, for example qawalah/my-app.", style="Error.TLabel")
            self.repo_entry.focus_set()
            return
        if repo.lower() in (r.lower() for r in self._rows):
            self.busy_label.configure(text=f"{repo} is already in the list.", style="Muted.TLabel")
            return

        def add() -> None:
            actions.add_app(repo)
            self.after(0, lambda: self.repo_var.set(""))

        self._run(f"Adding {repo}…", add, f"Added {repo}. It installs within a few minutes.")

    def on_remove(self) -> None:
        row = self._selected()
        if row is None:
            return
        if not messagebox.askyesno(
                "Remove app",
                f"Remove {row.display_name} from this PC?\n\n"
                f"Its program files and shortcut are deleted, and a service is stopped and uninstalled. "
                f"Its data in {actions.data_dir(row.name)} is kept.\n\n"
                f"To stop it coming back, don't add {row.repo} again.",
                icon="warning", default="no", parent=self):
            return
        self._run(f"Removing {row.display_name}…", lambda: actions.remove_app(row.repo), f"Removed {row.display_name}.")

    def on_service(self, action: str) -> None:
        row = self._selected()
        if row is None:
            return
        doing, done = {"Start": ("Starting", "Started"), "Stop": ("Stopping", "Stopped"),
                       "Restart": ("Restarting", "Restarted")}[action]
        self._run(f"{doing} {row.display_name}…", lambda: actions.service_action(row.name, action),
                  f"{done} {row.display_name}.")

    def on_launch(self) -> None:
        row = self._selected()
        if row is None or row.type != "App" or not row.installed:
            return
        state = self._states.get(row.repo.lower(), {})
        exe = state.get("exe") or f"{row.name}.exe"
        try:
            actions.launch(actions.app_exe(row.name, exe))
            self.busy_label.configure(text=f"Opened {row.display_name}.", style="Muted.TLabel")
        except OSError as e:
            self.busy_label.configure(text=f"Couldn't open {row.display_name}: {e}", style="Error.TLabel")

    def on_open_data(self) -> None:
        row = self._selected()
        if row is None:
            return
        try:
            actions.open_folder(actions.data_dir(row.name))
        except OSError as e:
            self.busy_label.configure(text=f"Couldn't open the data folder: {e}", style="Error.TLabel")


def main() -> None:
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)  # crisp text on high-DPI screens
        except (AttributeError, OSError):
            pass
    ManagerWindow().mainloop()
