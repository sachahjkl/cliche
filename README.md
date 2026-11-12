<p align="center"><img src="assets/logo_128.png" alt="" width="96"></p>

<h1 align="center">cliche</h1>

<p align="center">Fast screenshots and screen recordings, shared at once.</p>

cliche lives in the notification area. A shortcut takes a picture at once: a region drawn on the frozen screen (the
window under the pointer is framed for you), the screen under the pointer, or the window in front. The picture then goes
where you said: the clipboard, a PNG file.

`cliche --qr` reads a QR code instead: choose the region that holds it, and its text goes to the clipboard.

Pictures can also be uploaded to a host, its address copied: a built-in one, or any ShareX uploader (`.sxcu`).

`cliche --record` records a region as an MP4 video, `cliche --record-gif` as a GIF; the same command again stops it.

`cliche --edit` opens a region in the editor: arrows, boxes, text, step numbers, a pixelated part, red with a shadow by
default; each one stays movable until Done. `cliche --history` shows the captures kept, as a grid or a list.

## Use

    cliche                      start it (in the notification area)
    cliche --region             choose a rectangle, a window or a screen on the frozen desktop
    cliche --screen             capture the screen under the pointer
    cliche --window             capture the window in front
    cliche --qr                 read the QR code in a region: its text is copied
    cliche --ocr                read the text in a region: it is copied (Tesseract on Linux)
    cliche --record             record a region as an MP4 video; the same command again stops it
    cliche --record-gif         record a region as an animated GIF; the same command again stops it
    cliche --edit               capture a region and open it in the editor
    cliche --history            show the captures kept
    cliche --settings           open the settings
    cliche --quit               end the running cliche

Shortcuts work in every program: Print Screen for a region, Shift+Print Screen for the screen, Alt+Print Screen for the
window in front, Ctrl+Print Screen to record a video (Ctrl+Shift: a GIF), Ctrl+Alt+Q for a QR code, Ctrl+Alt+T for the
text in a region. Change them in the settings. On Linux the desktop portal gives them to cliche
(KDE, GNOME, Hyprland, ShojiWM's desktop); where it gives none, bind a key to `cliche --region` in the compositor.

In a region: drag a rectangle, it is taken when you release the button. A click takes the window under the pointer.
Escape gives up. With "Confirm on release" off, the rectangle stays: arrows move it a pixel (Ctrl: ten), Shift with
arrows resize it, and Enter or a click inside takes it.

The settings (`cliche --settings`, or the icon's menu): Ctrl+K opens the command palette, F1 lists the keys.

## Build

    ./build.sh            (Linux, in `nix develop`)
    build.bat             (Windows)

`odin run tools/clichetool ... -- help` lists every step. See [AGENTS.md](AGENTS.md).

## Licence

MIT. See [LICENSE](LICENSE).
