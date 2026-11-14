<p align="center"><img src="assets/logo_128.png" alt="" width="96"></p>

<h1 align="center">cliche</h1>

<p align="center">Fast screenshots and screen recordings, shared at once.</p>

cliche lives in the notification area. A shortcut takes a picture at once: a region drawn on the frozen screen (the
window under the pointer is framed for you), the screen under the pointer, or the window in front. The picture then runs
through its workflow.

A workflow is what happens after a capture, drawn as a graph that you edit: steps linked one to the next, with branches.
The picture can be resized, cropped, rotated, padded, given a border, rounded corners, a shadow or a coloured background,
a watermark, a change of colour (grayscale, brightness, saturation, hue, sepia...), a blur or a mosaic; a Condition sends
it one way or another (by its size, its source). At the end of each branch it is copied, saved, uploaded (its address
copied), read as a QR code or as text, or kept in the history. By default a screenshot is copied and saved,
`cliche --qr` copies the text of a QR code, and `cliche --ocr` the text of a region. Each capture's shortcut runs one
workflow: choose which in the main window's Workflows (Ctrl+Shift+W).

Uploads go to a built-in host or to any ShareX uploader (`.sxcu`).

`cliche --record` records a region as an MP4 video, `cliche --record-gif` as a GIF. Once the region is chosen, a frame
shows around it and a bar under it: nothing is recorded until you press Record. The bar then shows the time, Stop, and
Cancel, which deletes the recording. The same command again starts, then stops it; the icon turns red meanwhile.

`cliche --edit` opens a region in the editor (the Annotate step of its workflow): arrows, boxes, text, step numbers, a
pixelated part, red with a shadow by default; each one stays movable until Done, and the workflow goes on. Cancel stops
that branch of the workflow; a step linked to the editor's "cancelled" runs then instead.
`cliche --history` shows the captures kept, as a grid or a list.

## Use

    cliche                      start it (in the notification area)
    cliche --region             choose a rectangle, a window or a screen on the frozen desktop
    cliche --screen             capture the screen under the pointer
    cliche --window             capture the window in front
    cliche --all-screens        capture every screen in one picture
    cliche --last-region        capture the last region chosen again, with no overlay
    cliche --color              pick a colour on the screen: a click copies #rrggbb (Shift: rgb(r, g, b))
    cliche --qr                 read the QR code in a region
    cliche --ocr                read the text in a region (Tesseract on Linux)
    cliche --record             choose a region to record as an MP4 video; again: start, then stop
    cliche --record-gif         choose a region to record as an animated GIF; again: start, then stop
    cliche --edit               capture a region and open it in the editor
    cliche --history            open the main window: the captures kept
    cliche --workflows          open the main window on the workflows
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
    Ctrl+Alt+R                  the last region again
    Ctrl+Alt+C                  pick a colour on the screen
    Ctrl+Alt+E                  a region, then the editor ("Edit then share"'s own shortcut)

Change them in the settings. A workflow can have a shortcut of its own: its Capture step sets the keys, what they
capture (a region, the screen, the window in front, all the screens, the last region), a delay with a countdown, and
whether the pointer is in the picture (Wayland and Windows draw it; the screenshot portal and X11 cannot). The settings'
Shortcuts page lists every workflow's keys. On Linux the desktop portal gives them to cliche
(KDE, GNOME, Hyprland, ShojiWM's desktop); where it gives none, bind a key to `cliche --region` in the compositor.

In a region: drag a rectangle, it is taken when you release the button. A click takes the window under the pointer.
Escape gives up. With "Take the rectangle on release" off, the rectangle stays: drag its corners and edges to resize it,
its inside to move it; arrows move it a pixel (Ctrl: ten), Shift with arrows resize it; Enter or a double click inside
takes it.

The colour picker (`cliche --color`) shows the frozen screen with a magnifier: a click copies the colour under the
pointer as `#rrggbb`, Shift and a click as `rgb(r, g, b)`; the arrows move the pixel read, Enter takes it.

The main window shows the captures kept, as a grid or a list, with a preview you can widen. Its gear (or Ctrl+,) shows
the settings in its place, and its graph button (Ctrl+Shift+W) the workflows; Escape goes back. Ctrl+K opens the command
palette, F1 lists the keys.

In the workflows: a right click on the graph, Shift+A, or a link dropped on nothing adds a step (type to find it); drag
from a port to another to link them; Delete removes what is selected; Ctrl+Z undoes. The inspector on the right sets the
step selected, or the captures that run the workflow. "Run on the last capture" runs the workflow on the newest picture
of the history with nothing copied, saved or sent: each step shows what it made. The workflows are kept in
`workflows.json` in cliche's configuration folder.

## Build

    ./build.sh            (Linux, in `nix develop`)
    build.bat             (Windows)

`odin run tools/clichetool ... -- help` lists every step. See [AGENTS.md](AGENTS.md).

## Licence

MIT. See [LICENSE](LICENSE).
