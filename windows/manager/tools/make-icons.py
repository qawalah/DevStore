"""Regenerates the DevStore icons from the brand mark: store/icon.png (256 px,
store listing) and icon.ico (16-256 px, used for the exe, window, taskbar and
Start menu, by the Manager and the installer).

Run from anywhere with Playwright installed:  python windows/manager/tools/make-icons.py
"""
import io
import struct
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
MANAGER = HERE.parent
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def svg(size: int) -> str:
    # Thicker strokes at small sizes so the bag stays readable at 16 px.
    stroke = 2.6 if size <= 24 else 2.2 if size <= 48 else 1.9
    return f"""<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32' width='{size}' height='{size}'>
<rect width='32' height='32' rx='7.5' fill='#0e7c66'/>
<path d='M10 12h12l-1.2 11h-9.6z' fill='none' stroke='#fff' stroke-width='{stroke}' stroke-linejoin='round'/>
<path d='M13 12a3 3 0 0 1 6 0' fill='none' stroke='#fff' stroke-width='{stroke}' stroke-linecap='round'/></svg>"""


def render(page, size: int) -> bytes:
    page.set_viewport_size({"width": size, "height": size})
    page.set_content(f"<html><body style='margin:0;background:transparent'>{svg(size)}</body></html>")
    return page.screenshot(omit_background=True)


def ico(images: list[tuple[int, bytes]]) -> bytes:
    """ICO file with PNG-compressed entries (supported since Windows Vista)."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for size, png in images:
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset)
        blobs += png
        offset += len(png)
    return header + entries + blobs


def main() -> None:
    chrome = sys.argv[1] if len(sys.argv) > 1 else None
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chrome) if chrome else p.chromium.launch()
        page = browser.new_page()
        images = [(s, render(page, s)) for s in SIZES]
        browser.close()
    (MANAGER / "store").mkdir(exist_ok=True)
    (MANAGER / "store" / "icon.png").write_bytes(dict(images)[256])
    data = ico(images)
    (MANAGER / "icon.ico").write_bytes(data)
    (MANAGER.parent / "setup" / "icon.ico").write_bytes(data)
    print(f"wrote icon.ico ({len(data)} bytes, sizes {SIZES}) and store/icon.png")


if __name__ == "__main__":
    main()
