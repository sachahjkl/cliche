<img src="assets/logo_128.png" alt="" width="96" align="right">

# cliche

Fast screenshots and screen recordings, shared at once. For Linux (Wayland first, X11 too) and Windows.

cliche lives in the notification area. A shortcut takes a picture at once: a region drawn on the frozen screen (the
window under the pointer is framed for you), the screen under the pointer, or the window in front. The picture then goes
where you said: the clipboard, a PNG file.

`cliche --qr` reads a QR code instead: choose the region that holds it, and its text goes to the clipboard.

To come: screen recording (MP4, GIF), upload to a host of your choice (ShareX's `.sxcu` uploaders), a light OCR, an
editor.

## Use

    cliche                      start it (in the notification area)
    cliche --region             choose a rectangle, a window or a screen on the frozen desktop
    cliche --screen             capture the screen under the pointer
    cliche --window             capture the window in front
    cliche --qr                 read the QR code in a region: its text is copied
    cliche --settings           open the settings
    cliche --quit               end the running cliche

On Windows the settings register the shortcuts. On Wayland the compositor binds them: bind a key to `cliche --region`.

In a region: drag a rectangle; arrows move it a pixel (Ctrl: ten), Shift with arrows resize it; Enter or a click inside
takes it. A click elsewhere takes the window under the pointer. Escape gives up.

## Build

    ./build.sh            (Linux, in `nix develop`)
    build.bat             (Windows)

`odin run tools/clichetool ... -- help` lists every step. See [AGENTS.md](AGENTS.md).

## Licence

MIT. See [LICENSE](LICENSE).
