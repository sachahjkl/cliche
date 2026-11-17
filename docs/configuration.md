# Configuration

Cliche reads its preferences from `$XDG_CONFIG_HOME/FromentSoftware/Cliche/prefs` (a line `name<TAB>value` each, after the
first line). The settings (Ctrl+, or the history window's gear) show them on a page per subject, searched as you type,
each change applied at once. `--pref name=value` sets one for a single run:

```sh
cliche --pref record.fps=60 --pref region.magnifier=false
```

The settings page also exports them to JSON, TOML or INI, or to cliche's own format, which it imports back.

## The common settings

The look (`appearance.*`: the theme, light or dark, the finish, the glow, the text size, the zoom, the density, the
rounding...), the text and fonts (`appearance.text.*`), the window (`window.system_title`, `window.toast_position`), the
scrolling (`scrolling.*`), the input (`input.*`), the delays and menus (`timing.*`), the rendering (`rendering.*`), the
updates (`update.auto`, `update.channel`, `update.base_url`), the messages (`general.messages`, `general.language`) and
your keys and aliases of the commands (`keys.custom`, `keys.aliases`: set from the command palette, Ctrl+Enter and
Alt+Enter on a command) are the settings that every program of gui_toolkit has. Its
[docs/settings.md](https://github.com/sachahjkl/gui_toolkit/blob/main/docs/settings.md) lists each with its default.
Cliche's defaults: the theme `cliche`, the text size 14 px, its own title bar (`window.system_title` off).

`appearance.theme` is `cliche`, its own theme: a night blue for the surfaces and a coral accent. Then the toolkit's
themes by their name (Midnight, Graphite, Nord, Dracula, Gruvbox, Tokyo Night, Catppuccin, Rosé Pine, Kanagawa, One
Dark, Solarized...), or one of your own: the settings' Appearance page links to
`$XDG_CONFIG_HOME/FromentSoftware/Cliche/themes.txt`, made with a commented guide at the first click and read again
each time it is saved.

`appearance.text.*` sets the fonts: gui_toolkit loads a family and swaps it in every window at once. `general.menu` and
`general.autostart` are the install's (its dialog, `cliche --install`): the launcher in the applications menu, and the
start with the session, in the notification area.

## Cliche's own

Three preferences are the editor's memory of its last choices: `editor.tool`, `editor.styles` and `save.as_format`. The
settings do not show them.

| Name | Type | Default | What it does |
|---|---|---|---|
| `general.tray_click` | text, region, screen, window, qr, ocr, record, history or settings | region | What a click on Cliche's icon in the notification area does: capture a region, the screen, the window, read a QR code or the text, record a video, open the history or the settings. |
| `capture.ocr_languages` | text | empty | The languages of the text read in a region (`cliche --ocr`), as the engine names them, `+` between them (Tesseract: `eng+fra`). Empty: your languages. |
| `capture.auto_interval` | integer, 1 to 86400 seconds | 60 | The time between two captures of the auto capture. The tray's menu starts and stops it (`cliche --auto-capture`). |
| `capture.auto_source` | text, screen, window, all-screens or last-region | screen | What each capture of the auto capture takes: the screen under the pointer, the window in front, all the screens, or the last region (chosen at the first capture when there is none yet). Each runs the workflow of that capture. |
| `record.fps` | integer, 1 to 60 | 30 | The most frames a second of a video. Fewer come when the screen changes less. |
| `record.gif_fps` | integer, 1 to 30 | 12 | The most frames a second of a GIF. Fewer make smaller files. |
| `record.gif_width` | integer, 0 to 3840 pixels | 960 | The largest width of a GIF: a wider recording is scaled down. 0: its own size. |
| `record.cursor` | boolean | true | Shows the pointer in recordings, where the desktop can draw it in (Wayland and Windows; not the screenshot portal or X11). |
| `record.notify` | boolean | true | Shows a notification when a recording starts and when its file is written. |
| `record.reveal` | boolean | false | Shows a recording's file in its folder, in the file manager, once it is written. |
| `record.max_length` | integer, 0 to 3600 seconds | 0 | Stops a recording after this many seconds. 0: only when you stop it. |
| `history.size` | integer, 10 to 100000 | 1000 | How many captures the history keeps: the oldest go first. The files stay where they are. |
| `history.view` | text, grid or list | grid | How the history shows the captures: thumbnails in a grid, or a list with their details. |
| `history.thumbnail_size` | text, small, medium or large | medium | The size of the thumbnails in the grid. |
| `editor.tool` | text | empty | The tool the editor opens with, the last one used. |
| `editor.styles` | text | empty | Each tool's colour, width, shadow, fill and text size, as last used. |
| `region.confirm_on_release` | boolean | true | Takes the rectangle as soon as the button is released. Off: drag its corners and edges to resize it and its inside to move it, or use the arrow keys (Shift: resize), then press Enter or double-click inside it. |
| `region.frame_windows` | boolean | true | Frames the window under the pointer: a click takes it. Off: a click does nothing, only a drag chooses. |
| `region.magnifier` | boolean | true | Shows a magnifier near the pointer, with the pointer's position and the selection's size. |
| `region.dim` | fraction, 0 to 0.9 | 0.45 | How dark the screen is outside what is chosen. |
| `upload.uploader` | text | Litterbox (72 hours) | Where a workflow's Upload step sends pictures when it names no host, and where the history uploads again: the built-in host (anonymous, files kept 72 hours), or one of the ShareX uploaders (`.sxcu` files) in the uploaders' folder. |
| `save.folder` | text | empty | The folder of a workflow's Save step that names none, of the editor's Save, and of recordings. Empty: `Pictures/Screenshots` when it exists, else `Pictures/cliche`. |
| `save.quality` | fraction, 0.01 to 1 | 0.9 | The quality of a JPEG or WebP file the editor saves as (Save as...). Less makes smaller files that lose detail. A workflow's Save file step has its own. |
| `save.as_format` | text, png, jpeg or webp | png | The format the editor's Save as... chose last. |
| `save.name` | text | cliche-%Y%m%d-%H%M%S.png | The name of a saved file when its Save step names none: `%Y` year, `%m` month, `%d` day, `%H` hour, `%M` minute, `%S` second, `%f` milliseconds, `%s` the source (region, screen, window), `%%` a `%`. A name already taken gets " (2)". |
| `shortcut.screen` | keys | Print | Captures the whole screen under the pointer. |
| `shortcut.region` | keys | Ctrl+Print | Captures a region: drag a rectangle, click a window framed, or take a screen, on the frozen screen. |
| `shortcut.record` | keys | Shift+Print | Chooses a region to record as a video, then press Record. The same keys start the recording, then stop it. |
| `shortcut.record_gif` | keys | Ctrl+Shift+Print | Chooses a region to record as a GIF, then press Record. The same keys start the recording, then stop it. |
| `shortcut.window` | keys | Alt+Print | Captures the window in front. |
| `shortcut.ocr` | keys | Ctrl+Alt+T | Reads the text in a region: it goes to the clipboard. |
| `shortcut.qr` | keys | Ctrl+Alt+Q | Reads a QR code in a region: its text goes to the clipboard. |
| `shortcut.all_screens` | keys | empty | Captures every screen in one picture. Empty: no keys. |
| `shortcut.last_region` | keys | Ctrl+Alt+R | Captures the rectangle chosen last again, with no overlay. With none chosen yet: choose one. |
| `shortcut.color` | keys | Ctrl+Alt+C | Picks a colour on the screen: a click copies it as `#rrggbb`, Shift and a click as `rgb(r, g, b)`. |
| `shortcut.ruler` | keys | empty | Measures on the frozen screen: a drag draws a line with its length in pixels and its angle (Shift: a multiple of 45°). Escape ends it; nothing is captured. Empty: no keys. |

A shortcut is Ctrl, Shift, Alt, Win and a key, joined by `+`. Click its field in the settings and press the keys. On
Linux the desktop portal binds them, and may ask you first or give other keys; where it gives none, bind the command in
the compositor (`cliche --region`). A workflow's own keys are its Capture step's, and the settings' Shortcuts page lists
them.

The history's file is `$XDG_STATE_HOME/FromentSoftware/Cliche/history`; where each view opened is in its `views.txt`. They
are not preferences: deleting one gives its defaults back.

## Examples

Record at 60 frames a second, without the pointer:

```sh
cliche --pref record.fps=60 --pref record.cursor=false
```

Read the text in French and English:

```sh
cliche --pref capture.ocr_languages=eng+fra --ocr
```

Save every capture in one folder, under a name of your own:

```sh
cliche --pref save.folder="$HOME/Pictures/shots" --pref save.name="shot-%Y-%m-%d-%H%M%S.png"
```

A `--pref` value lasts for that run alone. To keep a change, use the settings (Ctrl+,).
