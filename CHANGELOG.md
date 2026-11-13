# Changelog

All notable changes to cliche are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [0.2.0] - 2026-11-13

### Added
- **cliche says when it cannot write its preferences**: if the disk is full or the folder cannot be made, a message names the file, instead of a change that is lost without a word.
- **Crash reports**: if cliche stops unexpectedly, the next start says so and names the file of its report, in the state folder (on Linux, `~/.local/state/cliche/crashes`). Nothing is sent anywhere. cliche also keeps a log there (`logs/cliche.log`); its last lines go into a report.
- **A licence to support cliche**: the General page of the settings says whether cliche is registered and to whom. Paste a licence key or choose a licence file to register; cliche checks it on your computer, with no network. cliche stays free and does the same with or without a licence.
- **More settings, your own themes, and export and import**: the pages Window, Scrolling, Input, Delays and menus, and Rendering join cliche's own pages, and Appearance now sets the text and the fonts. Each setting applies at once in every window. The technical settings are in a folded Advanced part. The Appearance page links to a file where you can write themes of your own; they show as soon as the file is saved. The settings export to a JSON, TOML or INI file and import back.
- **The editor has a Cancel button, and a workflow can wait for Done or Cancel**: an Annotate step has a "done" and a "cancelled" output. Link one of them to the "when" of a step that copies, saves, uploads, notifies or adds the picture to the history: that step then runs only when you press Done, or only when you cancel. Cancel skips the steps that need the edited picture, as closing the editor does.
- **cliche in French**: its menus, the tray, the history, the editor, the workflows and their steps, the recording bar, the notifications and the settings all show in French. The Language setting (Settings, General) chooses System, English or Français; System follows the language of the system. A new language takes effect at the next start. The French texts put a space before ":", ";", "?" and "!".

### Changed
- **On Windows, the history moves to the state folder**: it is now in `%LOCALAPPDATA%\cliche\state\history`. cliche no longer reads the history in `%LOCALAPPDATA%\cliche\history`.
- **Questions in the middle of the window, and one red for recording**: a question before cliche deletes or drops something (delete captures, delete a workflow, drop the editor's changes) shows in the middle of its window, not near its top. The red dot of the Record button and the red dot while a recording runs have the same red.
- **The editor remembers your choices and gives the shadow a size**:
  - It opens with the tool you used last, and each tool with the colour, width, shadow, fill and text size you gave it, also after cliche restarts.
  - The shadow of an annotation has a slider and a field, from 0 to 20 px, instead of on or off. It sets how soft the shadow is and how far it falls.
  - The tool in use shows pressed in, and the Done button has the colour of the theme's accent.

### Fixed
- **The shade around the selection shows its value**: the settings wrote "%!(MISSING ARGUMENT)" after its percentage.
- **Renaming a workflow and switching its triggers look smooth**: the name no longer shows only its last letters for a moment when its field opens, and the switches of the triggers slide instead of jumping.
- **Screenshots work again after the connection to the desktop breaks**: "No screenshot" came back at each capture until cliche restarted. The capture now reconnects by itself.

## [0.1.1] - 2026-11-12

### Added
- **cliche for Linux and Windows, ready to download**: each release has a Linux archive and a Windows one, with their SHA-256, and the site offers the one of your system.

## [0.1.0] - 2026-11-12

### Added
- **Workflows**: what happens after a capture is a graph you edit in the main window's Workflows (Ctrl+Shift+W, `cliche --workflows`). Steps linked one to the next, with branches: resize, crop, rotate, flip, pad, border, rounded corners, drop shadow, a coloured or gradient background, watermark, grayscale, invert, brightness and contrast, saturation, hue, sepia, threshold, blur, sharpen, pixelate, Annotate (the editor), a Condition on the picture's size or source, then copy, save, upload, copy the text, read a QR code or the text, notify, show in folder, add to history. Each step shows its settings under its title; "Run on the last capture" runs the workflow on the newest picture of the history, with nothing copied, saved or sent, and shows what each step made. Undo and redo every change. A run ends with one notification that says what was saved, uploaded, copied, and what failed.
- **Rename a workflow with a button**: a pencil beside New, Duplicate and Delete; the name says it can be double-clicked.
- **The Capture step shows its picture** in the Workflows mode, as every other step does.
- **Save as JPEG or WebP**: the Save file step of a workflow writes PNG, JPEG or WebP (lossy or lossless) at the quality you set, and the file name takes the right extension.
- **The icon's menu shows the keys of each command**, as the system gave them.
- **An editor to annotate a screenshot before it is copied, saved or uploaded**: `cliche --edit`, "Capture a region and edit" in the icon's menu, or each screenshot with "Open in the editor" on (Settings, After capture). Arrows, rectangles, ellipses, lines, a pen, text, a highlighter, pixelated boxes, numbered steps and a crop, in red with a thick stroke and a soft shadow at first. Each annotation stays one: select it to move, resize, recolour, duplicate or delete it; Ctrl+Z and Ctrl+Shift+Z undo and redo. Ctrl+wheel zooms, the middle button or Space pans. Done (Enter) runs the after-capture actions on the annotated picture; Ctrl+C copies it, Ctrl+S saves it; Ctrl+K lists every action and F1 every key.
- **A history of the captures.** `cliche --history`, "History" in the tray menu, or a click on cliche's notification opens a window with the latest screenshots, recordings, uploads, QR codes and texts read, as a grid of thumbnails or as a list sorted by its columns. Search by name, text or URL, and filter by kind. Open a capture or its folder, copy its picture, path, URL or text, edit it, upload it again, delete its file, or remove it from the history; Space shows a preview, Ctrl+K the command palette. The history keeps the last 1000 captures (the "Captures kept" setting).
- **Screen recordings**: `cliche --record` (Ctrl+Print Screen) records a region as an MP4 video, `cliche --record-gif` (Ctrl+Shift+Print Screen) as an animated GIF, chosen on the frozen screen as a screenshot's; the same keys again, or the icon in the notification area, stop it. A notification says where the file is, its size and its length. The Recording settings set the frame rates, the largest width of a GIF, the pointer and a maximum length.
- **Upload a screenshot and copy its address**: with "Upload" on (Settings, Upload), a picture goes to a host and its address replaces it on the clipboard. The built-in host needs no account and keeps files 72 hours; any ShareX custom uploader (.sxcu file) can be imported for other hosts.
- **Read the text on the screen**: `cliche --ocr` (Ctrl+Alt+T, or "Read the text" in the icon's menu) opens the region selection; the text in the chosen region goes to the clipboard. On Linux it needs Tesseract and its languages; on Windows, a language with text recognition.
- **Complete settings**: cliche's colours and the toolkit's themes, light or dark; a delay before a screen or a window is taken; how dark the screen is around a region, and whether a click takes the window under the pointer; the file shown in its folder after a save; small or fast PNG files; the save folder chosen in a dialog and opened; cliche in the application menu and started with the session; what a click on its icon does. Each page puts its settings back to their defaults at once, and the command palette (Ctrl+K) finds every setting and action.
- **Shortcuts that work in every program**: Print Screen captures a region, Shift+Print Screen the screen, Alt+Print Screen the window in front, Ctrl+Alt+Q reads a QR code. Change them in the settings: click a field and press the keys. On Linux the desktop gives them to cliche and may ask you to confirm; the settings say which keys each one got, and list the commands to bind where the desktop gives none.
- **Read a QR code on the screen**: `cliche --qr` (or "Read a QR code" in the tray menu) opens the region selection; the text of the QR code in the chosen region goes to the clipboard and shows in a notification.
- **Screenshots of a region, a screen or a window.** cliche lives in the notification area; `cliche --region`, `--screen` and `--window` (bound to keys by the compositor, or the shortcuts of the settings on Windows) take the picture. A region is drawn on the frozen desktop, with a magnifier; a click takes the window under the pointer; the arrow keys adjust the rectangle. The picture is copied to the clipboard and saved as a PNG file.

### Changed
- **Each picture opens in an editor of its own**: two screenshots to annotate are two editor windows, open together, and neither waits for the other's Done. Done or closing one goes on with, or stops, the workflow of its own picture only. "Edit" in the history opens a new editor too, beside those already open.
- **Each capture runs its workflow**: the shortcuts, the tray's items and the commands (`--region`, `--screen`, `--window`, `--edit`, `--qr`, `--ocr`) each run one workflow, chosen in the workflow's triggers. A capture may start while another one's workflow waits on the editor.
- **The list of captures shows their thumbnails**: its rows are taller, and the S, M, L sizes of the thumbnails apply to the list as to the grid.
- **The Copy of a shortcut command is a button with an icon** (Settings, Shortcuts).
- **The region's selection opens without the window animation**: it appears at once on the screen under the pointer, and takes the keyboard at once.
- **cliche says what it did in a system notification**: copied, saved, uploaded, deleted show as the system's notifications, not over the window. Where the system shows none, cliche's window says it. Settings, General, Messages: the system's, the window, or off (a failure is always said).
- **Copying a picture no longer stalls the windows**: its PNG for the clipboard is made in the background (a workflow's Copy image, the editor's Ctrl+C), or taken from its file (the history).
- **A screenshot reaches the editor four times sooner**: about 80 ms from the shortcut to the editor on a 4K screen, against 360 ms before. The picture is read in the order the editor takes, with no copy, and the editor is opened ahead, hidden, when each screenshot opens in it.
- **The editor's stroke width is a slider with its exact value**: drag it, type the width in pixels (1 to 40), turn the wheel over it, or press − and +.
- **Print Screen alone takes the whole screen**: Ctrl+Print Screen chooses a region, Shift+Print Screen records a region as a video, Ctrl+Shift+Print Screen as a GIF. Keys you set yourself stay as they are.
- **A recording starts when you press Record**: once the region is chosen, a frame shows around it and a bar under it, with Record, MP4 or GIF, and Cancel. While it records, the bar shows the time, Stop and Cancel (the recording is deleted), and the icon turns red.
- **One main window**: the history, with the settings in its place behind its gear (Ctrl+,); Escape goes back. The preview pane can be widened.
- **Recordings use the graphics card**: on an NVIDIA card (NVENC), on Intel and AMD (VA-API) and through Windows' own encoders, a video is encoded by the GPU; the processor's encoder (openh264) stays for the others.
- **A region is taken when the button is released**: no Enter needed. The rectangle that stays to be adjusted with the arrow keys is a setting (Region, "Confirm on release" off).

### Removed
- **The "After capture" settings**: copy, save, upload, open in the editor, show in folder and notify are steps of the workflows now. The default workflows do what the default settings did; the folder and the file name of the Save settings are the defaults of a Save step, the PNG compression a setting of each Save step, and the Upload settings' host the default of an Upload step. A recording's notification and "Show the file in its folder" are on the Recording page.

### Fixed
- **A region that cannot be captured says why**: the notification "No screenshot" had no text.
- **A Capture step's text no longer flickers** while the pointer moves over the workflow.
- **Recording no longer turns the screen black**: around the region being recorded, the desktop stays visible.
- **A shortcut can use the Super key** (Windows key): the settings record Super+S as they record Ctrl+S.
- **Print Screen takes the screen under the pointer** where the desktop says where the pointer is (a compositor with capture cursor sessions, X11, Windows); else the first screen, as before.
- **The editor's messages no longer hide its buttons**: they show at the bottom of the picture.
- **A capture can start while an editor is open**: the picture handed to the editor ends the capture, and its Done saves and tells it on its own.
- **A region is chosen on the screen it was asked on**: with two screens of the same size, the region showed the first screen's picture on the second.
- **The editor opens in front** of the window you were in, not behind it.
- **The window closes again** with its close button.
- **A recording of a region with an odd width or height is saved**: it failed with "the recording could not be saved".

[0.2.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.2.0
[0.1.1]: https://github.com/sachahjkl/cliche/releases/tag/v0.1.1
[0.1.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.1.0
