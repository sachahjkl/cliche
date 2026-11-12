package cliche

// The preferences: one registry (gt:config). The user's file is <config dir>/cliche/prefs; `--pref name=value`
// overrides a preference for one run. A preference is applied as soon as it changes (app_prefs_changed).

import "core:os"
import "core:strings"
import config "gt:config"
import "gt:platform"
import "gt:ui"

APP_NAME :: "cliche"

DEFAULT_NAME_PATTERN :: "cliche-%Y%m%d-%H%M%S.png"

// The pages of the settings, in this order (settings_view.odin gives their titles and icons). The choices of
// general.tray_click and save.compression are settings_view.odin's, with their words.
PREF_DEFS := [?]config.Def{
	// General
	{name = "general.menu", title = "In the application menu", category = "general", description = "Put cliche in the application menu, with its icon. The desktop then knows cliche by its name: its shortcuts and the windows' places come from that.", kind = .Bool, default = {b = true}, tags = {"launcher", "desktop file", "start menu", "icon"}},
	{name = "general.autostart", title = "Start with the session", category = "general", description = "Start cliche with the session, in the notification area, so that its shortcuts work from the start.", kind = .Bool, default = {b = false}, tags = {"login", "startup", "boot", "session"}},
	{name = "general.tray_click", title = "A click on the icon", category = "general", description = "What a click on cliche's icon in the notification area does.", kind = .String, default = {s = "region"}, tags = {"tray", "icon", "notification area", "panel"}},

	// Appearance
	{name = "appearance.theme", title = "Theme", category = "appearance", description = "The colours of cliche's windows: cliche's own, or a theme of the toolkit (Midnight, Nord, Gruvbox, Tokyo Night, Catppuccin, Rosé Pine...).", kind = .String, default = {s = "cliche"}, tags = {"colours", "colors", "palette", "dark", "light", "look"}},
	{name = "appearance.mode", title = "Light or dark", category = "appearance", description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.", kind = .String, default = {s = "system"}, choices = {"system", "dark", "light"}, tags = {"dark", "light", "night", "day"}},
	{name = "appearance.finish", title = "Finish", category = "appearance", description = "How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines. Edged: the same reliefs, crisp, with square corners. Flat: plain surfaces and thin lines.", kind = .String, default = {s = "machined"}, choices = {"machined", "edged", "flat", "gradient", "glass"}, tags = {"style", "look", "bevel", "flat"}},
	{name = "appearance.font_size", title = "Text size", category = "appearance", description = "The size of the settings' text, in logical pixels.", kind = .Float, default = {f = 14}, min = 10, max = 24, bounded = true, unit = "px", tags = {"text size", "zoom", "bigger", "smaller"}},

	// Capture
	{name = "capture.delay", title = "Delay before a screen or a window", category = "capture", description = "Seconds to wait before a screen or a window is taken (a menu opened meanwhile is in the picture). A region's picture is taken at once, frozen while you choose.", kind = .Int, default = {i = 0}, min = 0, max = 10, bounded = true, unit = "s", tags = {"timer", "wait", "countdown", "menu"}},

	{name = "capture.ocr_languages", title = "Languages of the text read", category = "capture", description = "The languages of the text read in a region (cliche --ocr), as the engine names them, \"+\" between them (Tesseract: eng+fra). Empty: your languages.", kind = .String, default = {s = ""}, tags = {"ocr", "text", "language", "tesseract", "recognition"}},

	// Recording
	{name = "record.fps", title = "Video frame rate", category = "record", description = "The most frames a second of a video. Fewer come when the screen changes less.", kind = .Int, default = {i = 30}, min = 1, max = 60, bounded = true, unit = "fps", tags = {"video", "mp4", "frame rate", "smooth"}},
	{name = "record.gif_fps", title = "GIF frame rate", category = "record", description = "The most frames a second of a GIF. Fewer make smaller files.", kind = .Int, default = {i = 12}, min = 1, max = 30, bounded = true, unit = "fps", tags = {"gif", "animation", "frame rate"}},
	{name = "record.gif_width", title = "Largest GIF width", category = "record", description = "The largest width of a GIF: a wider recording is scaled down. 0: its own size.", kind = .Int, default = {i = 960}, min = 0, max = 3840, bounded = true, unit = "px", tags = {"gif", "size", "scale", "resolution"}},
	{name = "record.cursor", title = "Show the pointer", category = "record", description = "Show the pointer in recordings, where the desktop can draw it in.", kind = .Bool, default = {b = true}, tags = {"mouse", "pointer", "cursor"}},
	{name = "record.max_length", title = "Longest recording", category = "record", description = "Stop a recording after this many seconds. 0: only when you stop it.", kind = .Int, default = {i = 0}, min = 0, max = 3600, bounded = true, unit = "s", tags = {"limit", "duration", "timer"}},

	// History
	{name = "history.size", title = "Captures kept", category = "history", description = "How many captures the history keeps: the oldest go first. The files stay where they are.", kind = .Int, default = {i = 1000}, min = 10, max = 100000, bounded = true, tags = {"history", "recent", "limit"}},
	{name = "history.view", title = "View", category = "history", description = "How the history shows the captures: thumbnails in a grid, or a list with their details.", kind = .String, default = {s = "grid"}, tags = {"grid", "list", "thumbnails"}},
	{name = "history.thumbnail_size", title = "Thumbnail size", category = "history", description = "The size of the thumbnails in the grid.", kind = .String, default = {s = "medium"}, tags = {"grid", "preview", "size"}},

	// Region
	{name = "region.confirm_on_release", title = "Take the rectangle on release", category = "region", description = "Take the rectangle as soon as the button is released. Off: adjust it with the arrow keys (Shift: resize), then press Enter or click inside it.", kind = .Bool, default = {b = true}, tags = {"fast", "enter", "adjust"}},
	{name = "region.frame_windows", title = "Frame the window under the pointer", category = "region", description = "Frame the window under the pointer: a click takes it. Off: a click does nothing, only a drag chooses.", kind = .Bool, default = {b = true}, tags = {"window", "hover", "click", "snap"}},
	{name = "region.magnifier", title = "Magnifier", category = "region", description = "Show a magnifier near the pointer, with the pointer's position and the selection's size.", kind = .Bool, default = {b = true}, tags = {"zoom", "loupe", "pixel"}},
	{name = "region.dim", title = "Shade around the selection", category = "region", description = "How dark the screen is outside what is chosen.", kind = .Int, default = {i = 45}, min = 0, max = 90, bounded = true, unit = "%", tags = {"shade", "darken", "overlay", "opacity"}},

	// After capture
	{name = "after.edit", title = "Open in the editor", category = "after", description = "Open each screenshot in the editor first: arrows, boxes, text; Done copies, saves and uploads it as the settings below say.", kind = .Bool, default = {b = false}, tags = {"annotate", "draw", "arrow", "markup"}},
	{name = "after.copy", title = "Copy to the clipboard", category = "after", description = "Copy the picture to the clipboard.", kind = .Bool, default = {b = true}, tags = {"clipboard", "paste"}},
	{name = "after.save", title = "Save as a file", category = "after", description = "Save the picture as a PNG file in the folder.", kind = .Bool, default = {b = true}, tags = {"file", "disk", "png"}},
	{name = "after.reveal", title = "Show the file in its folder", category = "after", description = "Show the saved file in its folder, in the file manager.", kind = .Bool, default = {b = false}, tags = {"open", "folder", "explorer", "files"}},
	{name = "after.notify", title = "Notify", category = "after", description = "Show a notification that says where the picture went.", kind = .Bool, default = {b = true}, tags = {"toast", "message"}},

	// Upload
	{name = "after.upload", title = "Upload and copy the address", category = "upload", description = "Upload the picture to the host below and copy its address to the clipboard, in place of the picture.", kind = .Bool, default = {b = false}, tags = {"share", "link", "url", "host", "sxcu", "imgur"}},
	{name = "upload.uploader", title = "Host", category = "upload", description = "Where pictures go: the built-in host (anonymous, files kept 72 hours), or one of the ShareX uploaders (.sxcu files) in the uploaders' folder.", kind = .String, default = {s = BUILTIN_UPLOADER_NAME}, tags = {"host", "sxcu", "sharex", "server"}},

	// Save
	{name = "save.folder", title = "Folder", category = "save", description = "The folder screenshots are saved in. Empty: Pictures/Screenshots when it exists, else Pictures/cliche.", kind = .String, default = {s = ""}, tags = {"directory", "path", "where"}},
	{name = "save.name", title = "File name", category = "save", description = "The name of a saved screenshot: %Y year, %m month, %d day, %H hour, %M minute, %S second, %f milliseconds, %s the source (region, screen, window), %% a %. A name already taken gets \" (2)\".", kind = .String, default = {s = DEFAULT_NAME_PATTERN}, tags = {"file name", "pattern", "format"}},
	{name = "save.compression", title = "PNG files", category = "save", description = "How hard the PNG file is compressed: small files, or fast saves (larger files).", kind = .String, default = {s = "small"}, tags = {"png", "size", "speed", "level"}},

	// Shortcuts
	{name = "shortcut.region", title = "Capture a region", category = "shortcuts", description = "Capture a region: a rectangle, a window or a screen chosen on the frozen screen.", kind = .String, default = {s = "Print"}, tags = {"hotkey", "keybinding", "keys", "print screen"}},
	{name = "shortcut.screen", title = "Capture the screen", category = "shortcuts", description = "Capture the screen under the pointer.", kind = .String, default = {s = "Shift+Print"}, tags = {"hotkey", "keybinding", "keys", "monitor", "print screen"}},
	{name = "shortcut.window", title = "Capture the window in front", category = "shortcuts", description = "Capture the window in front.", kind = .String, default = {s = "Alt+Print"}, tags = {"hotkey", "keybinding", "keys", "print screen"}},
	{name = "shortcut.record", title = "Record a video", category = "shortcuts", description = "Start recording a region as a video; the same keys stop it.", kind = .String, default = {s = "Ctrl+Print"}, tags = {"hotkey", "keybinding", "keys", "video", "mp4"}},
	{name = "shortcut.record_gif", title = "Record a GIF", category = "shortcuts", description = "Start recording a region as a GIF; the same keys stop it.", kind = .String, default = {s = "Ctrl+Shift+Print"}, tags = {"hotkey", "keybinding", "keys", "gif", "animation"}},
	{name = "shortcut.ocr", title = "Read the text", category = "shortcuts", description = "Read the text in a region: it goes to the clipboard.", kind = .String, default = {s = "Ctrl+Alt+T"}, tags = {"hotkey", "keybinding", "keys", "ocr", "text"}},
	{name = "shortcut.qr", title = "Read a QR code", category = "shortcuts", description = "Read a QR code in a region: its text goes to the clipboard.", kind = .String, default = {s = "Ctrl+Alt+Q"}, tags = {"hotkey", "keybinding", "keys", "barcode", "scan"}},
}

// What a click on the tray icon does (general.tray_click).
Tray_Click :: enum u8 { Region, Screen, Window, Qr, Ocr, Record, History, Settings }

TRAY_CLICK_NAMES := [Tray_Click]string{.Region = "region", .Screen = "screen", .Window = "window", .Qr = "qr", .Ocr = "ocr", .Record = "record", .History = "history", .Settings = "settings"}

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	menu, autostart:    bool,
	tray_click:         Tray_Click,
	theme:              string,
	mode:               ui.Theme_Mode,
	finish:             ui.Finish,
	font_size:          f32,
	delay_s:            int,
	record_fps, gif_fps, gif_width, record_max_s: int,
	record_cursor:      bool,
	history_size:       int,
	history_view:       History_View_Mode,
	history_thumbnail:  int,
	edit_after:         bool,
	ocr_languages:      string,
	confirm_on_release: bool,
	frame_windows:      bool,
	magnifier:          bool,
	dim:                f32,   // 0..1
	actions:            After_Capture_Set,
	reveal:             bool,
	uploader:           string,
	notify:             bool,
	folder:             string,   // "": the default folder (save_folder_default)
	name_pattern:       string,
	fast_png:           bool,
	shortcuts:          [Shortcut_Action]string,   // as platform.hotkey_parse reads them; "": none
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/prefs"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	config.register(p, PREF_DEFS[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.menu = config.bool_of(p, "general.menu")
	s.autostart = config.bool_of(p, "general.autostart")
	click := config.string_of(p, "general.tray_click")
	for name, c in TRAY_CLICK_NAMES { if name == click { s.tray_click = c } }
	s.theme = strings.clone(config.string_of(p, "appearance.theme"), allocator)
	s.mode = ui.theme_mode_of(config.string_of(p, "appearance.mode"))
	s.finish = ui.finish_of(config.string_of(p, "appearance.finish"))
	s.font_size = f32(config.float_of(p, "appearance.font_size"))
	s.delay_s = int(config.int_of(p, "capture.delay"))
	s.record_fps = int(config.int_of(p, "record.fps"))
	s.gif_fps = int(config.int_of(p, "record.gif_fps"))
	s.gif_width = int(config.int_of(p, "record.gif_width"))
	s.record_max_s = int(config.int_of(p, "record.max_length"))
	s.record_cursor = config.bool_of(p, "record.cursor")
	s.history_size, s.history_view, s.history_thumbnail = history_settings_read(p)
	s.edit_after = config.bool_of(p, "after.edit")
	s.ocr_languages = strings.clone(strings.trim_space(config.string_of(p, "capture.ocr_languages")), allocator)
	s.confirm_on_release = config.bool_of(p, "region.confirm_on_release")
	s.frame_windows = config.bool_of(p, "region.frame_windows")
	s.magnifier = config.bool_of(p, "region.magnifier")
	s.dim = f32(config.int_of(p, "region.dim")) / 100
	if config.bool_of(p, "after.copy") { s.actions += {.Copy} }
	if config.bool_of(p, "after.save") { s.actions += {.Save} }
	if config.bool_of(p, "after.upload") { s.actions += {.Upload} }
	s.reveal = config.bool_of(p, "after.reveal")
	s.uploader = strings.clone(config.string_of(p, "upload.uploader"), allocator)
	s.notify = config.bool_of(p, "after.notify")
	s.folder = strings.clone(strings.trim_space(config.string_of(p, "save.folder")), allocator)
	s.name_pattern = strings.clone(config.string_of(p, "save.name"), allocator)
	s.fast_png = config.string_of(p, "save.compression") == "fast"
	for pref, a in SHORTCUT_PREFS { s.shortcuts[a] = strings.clone(strings.trim_space(config.string_of(p, pref)), allocator) }
	return
}

settings_free :: proc(s: ^Settings, allocator := context.allocator) {
	delete(s.theme, allocator)
	delete(s.ocr_languages, allocator)
	delete(s.uploader, allocator)
	delete(s.folder, allocator)
	delete(s.name_pattern, allocator)
	for v in s.shortcuts { delete(v, allocator) }
	s^ = {}
}

// The default folder: Pictures/Screenshots when it exists (where most desktops put theirs), else Pictures/cliche. It reads
// the disk: the worker calls it.
save_folder_default :: proc(allocator := context.allocator) -> string {
	pictures := platform.known_folder_path(.Pictures, context.temp_allocator)
	if pictures == "" {
		home := platform.known_folder_path(.Home, context.temp_allocator)
		pictures = strings.concatenate({home, "/Pictures"}, context.temp_allocator)
	}
	shots := strings.concatenate({pictures, "/Screenshots"}, context.temp_allocator)
	if folder_exists(shots) { return strings.clone(shots, allocator) }
	return strings.concatenate({pictures, "/", APP_NAME}, allocator)
}

folder_exists :: proc(path: string) -> bool { return os.is_dir(path) }
