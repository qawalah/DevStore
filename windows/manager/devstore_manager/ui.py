"""Opens the DevStore store window: web/index.html in a native window
(Microsoft Edge WebView2, via pywebview), talking to api.Api."""
from __future__ import annotations

import sys
from pathlib import Path

WEB = Path(__file__).resolve().parent / "web"
WEBVIEW2_URL = "https://developer.microsoft.com/microsoft-edge/webview2/"


def _fail(message: str) -> None:
    """Last resort when the store window can't open: a plain Windows message box."""
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, message, "DevStore", 0x10)
    except (AttributeError, OSError):
        print(message, file=sys.stderr)


def main() -> None:
    from .api import Api
    try:
        import webview
    except ImportError as e:  # broken build
        _fail(f"DevStore couldn't start its window ({e}).")
        return
    window = webview.create_window("DevStore", url=str(WEB / "index.html"), js_api=Api(),
                                   width=1120, height=740, min_size=(760, 520), background_color="#f4f5f2")
    try:
        webview.start(gui="edgechromium", private_mode=False)
    except Exception as e:  # noqa: BLE001 - any start failure means the window can't open
        _fail("DevStore needs the Microsoft Edge WebView2 Runtime, which comes with Windows 11 and most "
              f"Windows 10 PCs. Install it from {WEBVIEW2_URL} and open DevStore again.\n\n({e})")
    del window
