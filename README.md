<p align="center"><img src="assets/logo_128.png" alt="" width="96"></p>

<h1 align="center">cliche</h1>

<p align="center">Fast screenshots and screen recordings, shared at once.</p>

cliche lives in the notification area. A shortcut takes a picture at once: a region drawn on the frozen screen (the
window under the pointer is framed for you), the screen under the pointer, or the window in front. The picture then goes
where you said: the clipboard, a PNG file.

`cliche --qr` reads a QR code instead: choose the region that holds it, and its text goes to the clipboard.

Pictures can also be uploaded to a host, its address copied: a built-in one, or any ShareX uploader (`.sxcu`).

`cliche --record` records a region as an MP4 video, `cliche --record-gif` as a GIF. Once the region is chosen, a frame
shows around it and a bar under it: nothing is recorded until you press Record. The bar then shows the time, Stop, and
Cancel, which deletes the recording. The same command again starts, then stops it; the icon turns red meanwhile.

`cliche --edit` opens a region in the editor: arrows, boxes, text, step numbers, a pixelated part, red with a shadow by
default; each one stays movable until Done. `cliche --history` shows the captures kept, as a grid or a list.

## Use

    cliche                      start it (in the notification area)
    cliche --region             choose a rectangle, a window or a screen on the frozen desktop
    cliche --screen             capture the screen under the pointer
    cliche --window             capture the window in front
    cliche --qr                 read the QR code in a region: its text is copied
    cliche --ocr                read the text in a region: it is copied (Tesseract on Linux)
    cliche --record             choose a region to record as an MP4 video; again: start, then stop
    cliche --record-gif         choose a region to record as an animated GIF; again: start, then stop
    cliche --edit               capture a region and open it in the editor
    cliche --history            open the main window: the captures kept
    cliche --settings           open the main window on the settings
    cliche --quit               end the running cliche

Shortcuts work in every program, and the icon's menu shows them:

    Print Screen                the whole screen under the pointer
    Ctrl+Print Screen           a region (a rectangle, a window or a screen)
    Shift+Print Screen          record a region as a video
    Ctrl+Shift+Print Screen     record a region as a GIF
    Alt+Print Screen            the window in front
    Ctrl+Alt+T                  read the text in a region
    Ctrl+Alt+Q                  read a QR code

Change them in the settings. On Linux the desktop portal gives them to cliche
(KDE, GNOME, Hyprland, ShojiWM's desktop); where it gives none, bind a key to `cliche --region` in the compositor.

In a region: drag a rectangle, it is taken when you release the button. A click takes the window under the pointer.
Escape gives up. With "Confirm on release" off, the rectangle stays: arrows move it a pixel (Ctrl: ten), Shift with
arrows resize it, and Enter or a click inside takes it.

The main window shows the captures kept, as a grid or a list, with a preview you can widen. Its gear (or Ctrl+,) shows
the settings in its place; Escape goes back. Ctrl+K opens the command palette, F1 lists the keys.

## Build

    ./build.sh            (Linux, in `nix develop`)
    build.bat             (Windows)

`odin run tools/clichetool ... -- help` lists every step. See [AGENTS.md](AGENTS.md).

## Licence

MIT. See [LICENSE](LICENSE).
