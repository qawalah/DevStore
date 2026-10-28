"""Minimal GUI app used to verify the DevStore Windows pipeline end to end."""
import json
import sys
import tkinter as tk
from pathlib import Path


def app_version() -> str:
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).parent
    try:
        return json.loads((base / "devstore.json").read_text())["version"]
    except (OSError, ValueError, KeyError):
        return "?"


def main() -> None:
    root = tk.Tk()
    root.title("DevStore Hello")
    root.geometry("320x120")
    tk.Label(root, text=f"DevStore Hello\nversion {app_version()}", font=("Segoe UI", 14)).pack(expand=True)
    root.mainloop()


if __name__ == "__main__":
    main()
