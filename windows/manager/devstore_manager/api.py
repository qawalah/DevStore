"""The bridge between the store window (web/app.js) and the PC: every public
method is callable from JavaScript as window.pywebview.api.<name>()."""
from __future__ import annotations

import base64
import datetime as dt
import os
import threading
from pathlib import Path
from typing import Optional

from . import actions, files, store

MAX_IMAGE_BYTES = 4 * 1024 * 1024


class Api:
    def __init__(self) -> None:
        self._images: dict[tuple[str, float], str] = {}
        self._services: dict[str, str] = {}
        self._view: dict = {}

    # ------------------------------------------------------------ reading

    def _image(self, rel: Optional[str]) -> Optional[str]:
        """Catalog-relative PNG path -> data: URI (cached), or None."""
        if not rel:
            return None
        path = actions.ROOT / Path(str(rel).replace("\\", "/"))
        try:
            stat = path.stat()
            key = (str(path), stat.st_mtime)
            if key not in self._images:
                if stat.st_size > MAX_IMAGE_BYTES:
                    return None
                self._images[key] = "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")
            return self._images[key]
        except OSError:
            return None

    def get_view(self) -> dict:
        root = actions.ROOT
        if not root.exists():
            return {"notInstalled": True, "root": str(root)}
        config = files.load_json(root / "config.json", {})
        state = files.load_json(root / "state.json", {})
        catalog = files.load_json(root / "catalog.json", {})
        services = [f"devstore-{a.get('name')}" for a in (store._by_repo(state.get("apps")).values())
                    if a.get("type") == "service" and a.get("name")]
        self._services = actions.service_statuses(services)
        view = store.build_view(config, state, catalog, self._services, actions.pending_requests(),
                                dt.datetime.now(dt.timezone.utc), running=actions.running_apps())
        for a in view["apps"]:
            a["iconData"] = self._image(a.get("icon"))
        view["settings"]["locations"] = self._locations()
        view["settings"]["version"] = app_version()
        self._view = view
        return view

    def get_details(self, repo: str) -> dict:
        app = self._find(repo)
        if app is None:
            return {"screenshots": [], "activity": [], "dataDir": ""}
        shots = [s for s in (self._image(p) for p in app.get("screenshots", [])) if s]
        activity = [e for e in store.parse_activity(files.read_log_lines(actions.LOG_DIR))
                    if e["app"] in (app["name"], app["repo"])][:50]
        return {"screenshots": shots, "activity": activity, "dataDir": str(actions.data_dir(app["name"]))}

    def get_activity(self) -> list[dict]:
        return store.parse_activity(files.read_log_lines(actions.LOG_DIR))

    def _find(self, repo: str) -> Optional[dict]:
        apps = self._view.get("apps") or self.get_view().get("apps", [])
        return next((a for a in apps if a["repo"].lower() == str(repo).lower()), None)

    # ------------------------------------------------------------ doing

    @staticmethod
    def _result(fn, ok_message: str) -> dict:
        try:
            fn()
            return {"ok": True, "message": ok_message}
        except actions.Cancelled:
            return {"ok": False, "message": "Cancelled: the Windows admin prompt was declined."}
        except (actions.ActionFailed, ValueError, OSError) as e:
            return {"ok": False, "message": str(e)}

    def install(self, repo: str) -> dict:
        return self._result(lambda: actions.install(repo), "Installing. This usually takes under a minute.")

    def remove(self, repo: str) -> dict:
        return self._result(lambda: actions.remove(repo), "Removing. Its data folder is kept.")

    @staticmethod
    def _locations() -> dict:
        return {"programs": str(actions.ROOT / "apps"), "data": str(actions.data_dir("")).rstrip("\\/"),
                "logs": str(actions.LOG_DIR)}

    def open_location(self, kind: str) -> dict:
        path = self._locations().get(kind)
        if not path:
            return {"ok": False, "message": "Unknown folder."}
        return self._result(lambda: actions.open_folder(Path(path)), "Opened the folder.")

    def update(self, repo: str) -> dict:
        return self._result(lambda: actions.apply_update(repo), "Updating. This usually takes under a minute.")

    def set_updates(self, repo: Optional[str], mode: str) -> dict:
        labels = {"auto": "Updates install automatically", "download": "Updates download; you choose when to install",
                  "notify": "DevStore only tells you about updates", "default": "Updates follow your default setting"}
        return self._result(lambda: actions.set_updates(repo or None, mode), labels.get(mode, "Saved") + ".")

    def check_now(self) -> dict:
        return self._result(actions.check_now, "Checking for updates now.")

    def open_app(self, repo: str) -> dict:
        app = self._find(repo)
        if app is None:
            return {"ok": False, "message": "App not found."}
        return self._result(lambda: actions.launch(actions.app_exe(app["name"], app["exe"])), f"Opening {app['displayName']}.")

    def relaunch_app(self, repo: str) -> dict:
        """Force close, then open again. For DevStore itself: open the new version, then quit this one."""
        app = self._find(repo)
        if app is None:
            return {"ok": False, "message": "App not found."}
        if app["isSelf"]:
            def restart_self() -> None:
                actions.launch(actions.app_exe(app["name"], app["exe"]))
                threading.Timer(0.8, os._exit, args=(0,)).start()
            return self._result(restart_self, "Restarting DevStore…")
        return self._result(lambda: actions.relaunch_app(app["name"], app["exe"]), f"Restarted {app['displayName']}.")

    def close_app(self, repo: str) -> dict:
        app = self._find(repo)
        if app is None or app["isSelf"]:
            return {"ok": False, "message": "App not found."}

        def close() -> None:
            if actions.close_app(app["name"]) == 0:
                raise ValueError(f"{app['displayName']} wasn't running, or Windows didn't allow closing it.")
        return self._result(close, f"Closed {app['displayName']}.")

    def open_data(self, repo: str) -> dict:
        app = self._find(repo)
        if app is None:
            return {"ok": False, "message": "App not found."}
        return self._result(lambda: actions.open_folder(actions.data_dir(app["name"])), "Opened the data folder.")

    def service(self, repo: str, action: str) -> dict:
        app = self._find(repo)
        if app is None:
            return {"ok": False, "message": "App not found."}
        done = {"Start": "Started", "Stop": "Stopped", "Restart": "Restarted"}.get(action, action)
        return self._result(lambda: actions.service_action(app["name"], action), f"{done} {app['displayName']}.")

    def version(self) -> str:
        return app_version()


def app_version() -> str:
    import json
    import sys
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent.parent
    try:
        return json.loads((base / "devstore.json").read_text(encoding="utf-8"))["version"]
    except (OSError, ValueError, KeyError):
        return "dev"
