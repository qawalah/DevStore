"""Minimal background service used to verify the DevStore Windows pipeline.

Writes a heartbeat line every 5 seconds to
%ProgramData%\\hello-windows-service\\heartbeat.log and exits cleanly on
SIGINT / SIGTERM / SIGBREAK (what WinSW sends when stopping the service).
"""
import datetime
import os
import signal
import threading
from pathlib import Path

NAME = "hello-windows-service"
VERSION = "1.0.0"
stop = threading.Event()


def data_dir() -> Path:
    path = Path(os.environ.get("ProgramData", Path.home())) / NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def main() -> None:
    for sig in ("SIGINT", "SIGTERM", "SIGBREAK"):
        if hasattr(signal, sig):
            signal.signal(getattr(signal, sig), lambda *_: stop.set())
    log = data_dir() / "heartbeat.log"
    while not stop.is_set():
        with log.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {NAME} {VERSION} alive\n")
        stop.wait(5)
    with log.open("a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} {NAME} {VERSION} stopped\n")


if __name__ == "__main__":
    main()
