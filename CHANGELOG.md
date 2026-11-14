# Changelog

All notable changes to cliche are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [0.5.0] - 2026-11-14

### Added
- **Every step that acts says when it is done**: the steps that copy, save, upload, shorten, notify, open, pin, show in folder, delete or add to the history have a "done" output, and Upload a "failed" one. Link it to another step's "when": that step waits for it, for example Ask once the file is saved, or Save file when the upload failed.

## [0.4.0] - 2026-11-14

### Added
- **The history opens addresses, pins, combines and filters by date; the tray shows recent captures**:
  - "Open the URL" (Shift+Enter) opens an upload's address in the browser.
  - "Pin to the screen" keeps a picture over every other window.
  - Select two pictures or more, then "Combine side by side" or "Combine stacked": cliche saves them as one new picture in the save folder.
  - The calendar button shows today, the last 7 days or the last 30 days.
  - "Upload again" (Ctrl+U) now takes any file, not only a picture.
  - The tray's Recent submenu lists the last five entries; a click opens the address or the file.
- **Upload the clipboard or files**: `cliche --upload-clipboard` and the tray send what the clipboard holds: a picture, files or a text. `cliche --upload-file` and the tray open a dialog to choose files. Each runs the new Upload workflow, which copies the address and keeps it in the history. The Upload step now takes a picture, a file or a text.
- **New workflow steps: Shorten URL, Open, Delete file, Ask, Pin to the screen, Make QR code**:
  - Shorten URL shortens an address with is.gd, v.gd or a ShareX URL shortener.
  - Open opens an address in the browser, or a file with its program.
  - Delete file deletes a file, for example once the Upload step's new "done" fires.
  - Ask shows a question in a notification; its "yes" and "no" decide what runs next.
  - Pin to the screen keeps a picture over the other windows.
  - Make QR code makes the picture of a QR code from a text.
- **A shortcut for each workflow**: a workflow's Capture step records keys of its own and what they capture: a region, the screen, the window in front, all the screens or the last region. "Edit then share" has Ctrl+Alt+E: a region, then the editor. The settings' Shortcuts page lists the keys of every workflow and what the system made of them, with a button to change them.
- **Pick a colour on the screen**: `cliche --color` (Ctrl+Alt+C, the icon's menu, the command palette) shows the frozen screen with a magnifier and the colour under the pointer. A click copies it as `#rrggbb`, Shift and a click as `rgb(r, g, b)`, and a notification says it. The arrow keys move the pixel read, and Enter takes it.
- **Capture the last region again, or all the screens**: `cliche --last-region` (Ctrl+Alt+R) captures the rectangle chosen last, with no overlay; the first time, you choose one. `cliche --all-screens` captures every screen in one picture. Both are in the icon's menu, the command palette and the workflows' triggers, and run the screenshot's workflow by default.
- **Move and resize a region with the mouse**: with "Take the rectangle on release" off, the rectangle drawn has grips at its corners and edges. Drag a grip to resize it and drag its inside to move it; the pointer's shape says which. Enter or a double click inside takes it, and Escape gives it up. The arrow keys move it (with Ctrl, ten pixels), and with Shift they resize it.
- **The editor opens JPEG, WebP and BMP, and files dropped on it**: the editor opens PNG, JPEG, WebP and BMP pictures, read by their content, not their name. A picture file dropped on an editor opens in an editor of its own.
- **Pin a picture to the screen**: Ctrl+T, or the pin in the editor's bar, keeps the picture over every other window. Drag it to move it and use the wheel to zoom it. A right click offers copy, save and close; a double click or Escape closes it. The history and the workflows can pin a picture too. If the desktop lets no window stay on top (GNOME), the picture opens in a normal window.
- **Save as, upload and print from the editor**:
  - Ctrl+Shift+S opens the system's save dialog, with the name the default pattern gives. The file is PNG, JPEG or WebP, by the type chosen or the extension typed. The Save page sets the JPEG and WebP quality, and the dialog offers the format chosen last first.
  - Ctrl+U, or its button in the bar, sends the picture to the default host. Its address goes to the clipboard and to the history, and a message says so.
  - Ctrl+P opens the system's print dialog and prints the picture on one page, at its size on the screen, smaller when it does not fit. On Linux, cliche prints through the print portal.
- **Turn, mirror, resize, add margins and trim the picture**: the editor's Picture menu turns the picture right (Ctrl+R) or left (Ctrl+Shift+R), mirrors it, resizes it with its ratio kept or not (Ctrl+Alt+R), adds margins of a colour (Ctrl+Alt+M) and trims its plain edges (Ctrl+Shift+X). The crop has handles to adjust it after it is drawn. The annotations follow the picture, and one undo reverses each change.
- **Select, order, resize, paste and insert annotations**:
  - With the Select tool, a drag on the picture selects what it touches, Shift and a click adds or removes an annotation, and Ctrl+A selects them all. A move, a property, the order and a delete apply to the whole selection.
  - A right click on an annotation offers Delete, Duplicate (Ctrl+D), and Bring to front, Bring forward, Send backward, Send to back (Home, Page Up, Page Down, End). Ctrl+Shift+Delete deletes every annotation.
  - A selected text, step number or drawing has a handle at its bottom right that makes it larger or smaller.
  - Ctrl+V pastes the clipboard's picture on the picture, to move and resize, or its text as a text annotation.
  - The Insert menu puts a picture from a file (Ctrl+I), the last screenshot of the history (Ctrl+Shift+I), a mouse pointer or an emoji on the picture. Each moves and scales as any annotation.
- **New options for the editor's annotations**:
  - Colours: past the swatches, the colour picker gives any colour. Boxes, ellipses, balloons, steps and texts have a fill colour apart from their outline's, with its opacity, or no fill.
  - Lines: rectangles, ellipses, lines, arrows, drawings, balloons and magnifiers can be drawn in dashes or dots. A rectangle can have rounded corners.
  - Arrow heads: an arrow has its head at the end, at the start or at both ends. A freehand drawing can have heads too.
  - Texts: Shift+Enter starts a new line and Enter ends the text. A text can be bold, and shows its letters alone, with an outline, or on a box.
  - Steps: the Step tool sets the next number, or a selected step's own, and writes it as 1, 2, 3; a, b, c; A, B, C; or i, ii, iii.
  - Pixelate has four pixel sizes.
- **New tools in the editor**:
  - Blur (G) blurs a part of the picture, with four strengths.
  - Speech balloon (Q) is a rounded box with a tail; the tail's tip has its own handle. You type its words as soon as it is drawn.
  - Magnifier (M) shows the picture under it 1.5, 2, 3 or 4 times larger, in a circle or a rectangle, with an edge.
  - Smart eraser (X) covers a part of the picture with the colour around it: a text or a detail on a plain background disappears.
  - Cut out a band (K) removes a band of rows or columns and joins the rest.
- **cliche does what ShareX's editor and capture do**: the editor has the tools and options of ShareX's (blur, speech balloons, magnifiers, a smart eraser, dashed lines, fill colours, a Picture menu) and saves, uploads, pins and prints the picture itself. The capture adds the last region, all the screens, a colour picker, a delay and the pointer, and each workflow can have its own shortcut. Workflows, the history and the tray menu do more with what was captured. The entries below give the details.

### Changed
- **A click on a workflow's notification opens what it made**: the address it uploaded opens in the browser, else the file it saved opens with its program. A notification with neither still shows the history.
- **A delay and the pointer for each workflow**: the delay before a capture (0 to 30 s) is now a parameter of the workflow's Capture step, for every source, a region too. A notification counts it down and is gone before the picture is taken. The same step can show the pointer in the picture: on Wayland and Windows; the screenshot portal and X11 cannot. The setting "Delay before a screen or a window" is gone.
- **The editor's zoom, and a bar that folds tool by tool**: the bar shows the zoom in percent; a click on it offers fit, 50, 100, 200 and 400 %, and Ctrl+1 shows the actual size. In a narrow window, the bar moves its buttons into its "…" panel one at a time: the rare tools and the menus first, the colours late, the everyday tools last. Cancel and Done always stay.

## [0.3.2] - 2026-11-14

### Fixed
- **cliche starts on Windows**: Windows refused to start cliche 0.3.0 and 0.3.1 (their manifest was broken). This version starts.

## [0.3.1] - 2026-11-14

### Fixed
- **cliche starts on Windows again**: Windows refused to start the 0.3.0 program. Dialogs also open at their final size, without a jump.

## [0.3.0] - 2026-11-13

### Added
- **A Diagnostics page in the settings, with a Copy button.** It shows the versions, the system, the graphics adapter (and whether a software rasterizer draws), the window's size and scale, the last frames' times and how much partial redraw drew. If cliche is slow, copy it and send it.
- **cliche installs itself: an Installation page in the settings.** It says where the installed copy is, its version, and whether this copy is the installed one. It shows the menu entry, Settings > Apps, the start with the session and the PATH, with Install, Repair, Upgrade and Uninstall. The palette finds the page ("install"). On Windows, a copy that is not installed offers the install when its window first shows.
The command line has `--install`, `--uninstall`, `--status` (what is installed, and whether cliche runs) and `--setup`, as in the other programs.
- **cliche updates itself, as the other programs of Froment Software.** The installed copy looks for a new version a while after the start and then every day. It checks the signature and puts the new version in place. Then cliche starts again in the notification area, when no window shows and nothing is under way. The settings have an Updates page: Update by itself, the state, Check now, Install and Restart now. The palette has "Check for updates". If cliche runs from the Nix store, Nix updates it.

### Changed
- **The licence has its own page in the settings, worded as in the other programs.** It says whether cliche is registered. It offers Buy a licence, a field to paste a key, Choose a licence file… and Remove the licence.
- **A crash of the last session shows in a bar at the top of the main window**, in place of a notification with the report's path. The bar says what happened and offers Open the report, Copy and Report on GitHub (a new issue with the report in it). Its cross dismisses it.
- **A change of language shows at once**: the windows, the settings and the tray menu take the new language without a restart.
- **cliche has the same settings as the other programs of Froment Software.** Only its theme is its own, and its defaults stay the same. The settings' reset button has the same arrow as in the other programs. The "system's title bar" switch is gone: cliche's windows always have the system's title bar, and the switch changed nothing.

### Fixed
- **Windows: cliche shows its icon and its publisher.** The editor, the settings and every other window show cliche's icon in the title bar and the taskbar, and they group under cliche's shortcut. Explorer and Task Manager show cliche's name, version and publisher, Froment Software, as for the other programs; the next start writes the menu entry again under this name. The archive has `cliche.com` beside `cliche.exe`: `cliche --help` in cmd or PowerShell prints there.
- **French done right.** Keys have the names that a French keyboard prints ("Maj+Impr. écran") in the tooltips and the tray menu. Numbers use the French decimal mark and spacing, and frame rates read "i/s". Workflows are called "scénarios" everywhere. The file name's source words are explained, and the editor's window has a French title.
- **The history's tool bar never cuts its text.** The filter, the thumbnail size and Grid or List are as wide as their longest word in every language. If the window is too narrow for them beside the search, they move to their own line.
- **The editor fits its window.** In a narrow window, the properties, then undo, redo, copy and save, then the tools go into a "…" menu at the end of the tool bar; Cancel and Done always show. The editor takes the size that the desktop gives it: on a tiling desktop (sway), it fills its tile and follows its resizes, and its tool bar is no longer cut. The question before the changes are dropped is as wide as its title and its buttons, and its Cancel is no longer red.

## [0.2.2] - 2026-11-13

### Changed
- **One licence at one price, and a new pricing page**: the cliche licence is now one edition at 15 €, paid once, taxes included; the Patron edition is gone. The pricing page shows cliche's icon and name, one card with the price, what the licence gives as a list, one button, then "Before you buy". The licence is named "cliche licence" on the site, at checkout and in the licence file.

## [0.2.1] - 2026-11-13

### Fixed
- **The Windows download is there again**: 0.2.0 had no Windows archive (its build stopped on a check that read the files with Windows line endings). This version has it.

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

[0.5.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.5.0
[0.4.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.4.0
[0.3.2]: https://github.com/sachahjkl/cliche/releases/tag/v0.3.2
[0.3.1]: https://github.com/sachahjkl/cliche/releases/tag/v0.3.1
[0.3.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.3.0
[0.2.2]: https://github.com/sachahjkl/cliche/releases/tag/v0.2.2
[0.2.1]: https://github.com/sachahjkl/cliche/releases/tag/v0.2.1
[0.2.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.2.0
[0.1.1]: https://github.com/sachahjkl/cliche/releases/tag/v0.1.1
[0.1.0]: https://github.com/sachahjkl/cliche/releases/tag/v0.1.0
