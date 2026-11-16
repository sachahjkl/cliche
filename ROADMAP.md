# Roadmap

## Now

- **Check the ShareX parity on a real desktop.** The lots of `docs/sharex.md` each list what a test without a window
  cannot see: the pinned pictures over other windows, the print dialog, the drops on the editor, the region's grips. A
  person tries each one on Linux and on Windows.

## Next

- **The region on every monitor, on Wayland, from the tray.** Started from the tray, the overlay is the first window and
  stays on the output of the first capture. Another output needs the toolkit's renderer to outlive its first window.
  Intent: [src/md/features/region-overlay.md](src/md/features/region-overlay.md).

## Later

- **Scrolling capture.** One tall picture of a page that scrolls, stitched from its screens. The design is in
  `docs/sharex.md`, "Decisions"; Windows first.
- **Auto capture.** A capture every N seconds, started and stopped from the tray.
- **Ruler.** The frozen screen, a line drawn on it, its length in pixels and its angle; nothing is captured.
- **Share an address.** An uploaded picture's address sent to a sharing service of a ShareX uploader (`.sxcu`).
