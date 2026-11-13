package cliche

// The preferences: one registry (gt:config). The user's file is <config dir>/cliche/prefs; `--pref name=value`
// overrides a preference for one run. A preference is applied as soon as it changes (app_prefs_changed).

import "core:os"
import "core:strings"
import "core:sync"
import config "gt:config"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"

APP_NAME :: "cliche"

DEFAULT_NAME_PATTERN :: "cliche-%Y%m%d-%H%M%S.png"

// The pages of the settings, in this order (settings_view.odin gives their titles and icons). What happens after a
// capture is not here: it is the workflows (workflow.odin). The choices of general.tray_click are settings_view.odin's,
// with their words. The look, the text, scrolling, input, the delays, rendering and the session (general.menu,
// general.autostart, general.messages) are the toolkit's standard preferences (prefs_register, gui_toolkit
// docs/settings.md).
PREF_DEFS := [?]config.Def{
	// General
	{name = "general.tray_click", title = i18n.later("A click on the icon"), description = i18n.later("What a click on cliche's icon in the notification area does."), kind = .String, default = {s = "region"}, tags = {"tray", "icon", "notification area", "panel"}},

	// Capture
	{name = "capture.delay", title = i18n.later("Delay before a screen or a window"), description = i18n.later("Seconds to wait before a screen or a window is taken (a menu opened meanwhile is in the picture). A region's picture is taken at once, frozen while you choose."), kind = .Int, default = {i = 0}, min = 0, max = 10, bounded = true, unit = "s", tags = {"timer", "wait", "countdown", "menu"}},

	{name = "capture.ocr_languages", title = i18n.later("Languages of the text read"), description = i18n.later("The languages of the text read in a region (cliche --ocr), as the engine names them, \"+\" between them (Tesseract: eng+fra). Empty: your languages."), kind = .String, default = {s = ""}, tags = {"ocr", "text", "language", "tesseract", "recognition"}},

	// Recording
	{name = "record.fps", title = i18n.later("Video frame rate"), description = i18n.later("The most frames a second of a video. Fewer come when the screen changes less."), kind = .Int, default = {i = 30}, min = 1, max = 60, bounded = true, unit = "fps", tags = {"video", "mp4", "frame rate", "smooth"}},
	{name = "record.gif_fps", title = i18n.later("GIF frame rate"), description = i18n.later("The most frames a second of a GIF. Fewer make smaller files."), kind = .Int, default = {i = 12}, min = 1, max = 30, bounded = true, unit = "fps", tags = {"gif", "animation", "frame rate"}},
	{name = "record.gif_width", title = i18n.later("Largest GIF width"), description = i18n.later("The largest width of a GIF: a wider recording is scaled down. 0: its own size."), kind = .Int, default = {i = 960}, min = 0, max = 3840, bounded = true, unit = "px", tags = {"gif", "size", "scale", "resolution"}},
	{name = "record.cursor", title = i18n.later("Show the pointer"), description = i18n.later("Show the pointer in recordings, where the desktop can draw it in."), kind = .Bool, default = {b = true}, tags = {"mouse", "pointer", "cursor"}},
	{name = "record.notify", title = i18n.later("Notify"), description = i18n.later("Show a notification when a recording starts and when its file is written."), kind = .Bool, default = {b = true}, tags = {"toast", "message"}},
	{name = "record.reveal", title = i18n.later("Show the file in its folder"), description = i18n.later("Show a recording's file in its folder, in the file manager, once it is written."), kind = .Bool, default = {b = false}, tags = {"open", "folder", "explorer", "files"}},
	{name = "record.max_length", title = i18n.later("Longest recording"), description = i18n.later("Stop a recording after this many seconds. 0: only when you stop it."), kind = .Int, default = {i = 0}, min = 0, max = 3600, bounded = true, unit = "s", tags = {"limit", "duration", "timer"}},

	// History
	{name = "history.size", title = i18n.later("Captures kept"), description = i18n.later("How many captures the history keeps: the oldest go first. The files stay where they are."), kind = .Int, default = {i = 1000}, min = 10, max = 100000, bounded = true, tags = {"history", "recent", "limit"}},
	{name = "history.view", title = i18n.later("View"), description = i18n.later("How the history shows the captures: thumbnails in a grid, or a list with their details."), kind = .String, default = {s = "grid"}, tags = {"grid", "list", "thumbnails"}},
	{name = "history.preview_width", title = "Preview width", description = "The width of the preview pane, in ems. Dragging the line beside it changes it.", kind = .Float, default = {f = HISTORY_PREVIEW_EM}, min = HISTORY_PREVIEW_MIN_EM, max = HISTORY_PREVIEW_MAX_EM, bounded = true, hidden = true},
	{name = "history.thumbnail_size", title = i18n.later("Thumbnail size"), description = i18n.later("The size of the thumbnails in the grid."), kind = .String, default = {s = "medium"}, tags = {"grid", "preview", "size"}},

	// Editor: the last choices, as they were when an editor last closed (editor_choices_keep)
	{name = "editor.tool", title = "Editor tool", description = "The tool the editor opens with: the last one used.", kind = .String, default = {s = ""}, hidden = true},
	{name = "editor.styles", title = "Editor styles", description = "Each tool's colour, width, shadow, fill and text size, as last used.", kind = .String, default = {s = ""}, hidden = true},

	// Region
	{name = "region.confirm_on_release", title = i18n.later("Take the rectangle on release"), description = i18n.later("Take the rectangle as soon as the button is released. Off: adjust it with the arrow keys (Shift: resize), then press Enter or click inside it."), kind = .Bool, default = {b = true}, tags = {"fast", "enter", "adjust"}},
	{name = "region.frame_windows", title = i18n.later("Frame the window under the pointer"), description = i18n.later("Frame the window under the pointer: a click takes it. Off: a click does nothing, only a drag chooses."), kind = .Bool, default = {b = true}, tags = {"window", "hover", "click", "snap"}},
	{name = "region.magnifier", title = i18n.later("Magnifier"), description = i18n.later("Show a magnifier near the pointer, with the pointer's position and the selection's size."), kind = .Bool, default = {b = true}, tags = {"zoom", "loupe", "pixel"}},
	{name = "region.dim", title = i18n.later("Shade around the selection"), description = i18n.later("How dark the screen is outside what is chosen."), kind = .Int, default = {i = 45}, min = 0, max = 90, bounded = true, unit = "%", tags = {"shade", "darken", "overlay", "opacity"}},

	// Upload
	{name = "upload.uploader", title = i18n.later("Default host"), description = i18n.later("Where a workflow's Upload step sends pictures when it names no host, and where the history uploads again: the built-in host (anonymous, files kept 72 hours), or one of the ShareX uploaders (.sxcu files) in the uploaders' folder."), kind = .String, default = {s = BUILTIN_UPLOADER_NAME}, tags = {"host", "sxcu", "sharex", "server", "share", "link", "url", "imgur"}},

	// Save
	{name = "save.folder", title = i18n.later("Default folder"), description = i18n.later("The folder of a workflow's Save step that names none, of the editor's Save, and of recordings. Empty: Pictures/Screenshots when it exists, else Pictures/cliche."), kind = .String, default = {s = ""}, tags = {"directory", "path", "where"}},
	{name = "save.name", title = i18n.later("Default file name"), description = i18n.later("The name of a saved file when its Save step names none: %Y year, %m month, %d day, %H hour, %M minute, %S second, %f milliseconds, %s the source (region, screen, window), %% a %. A name already taken gets \" (2)\"."), kind = .String, default = {s = DEFAULT_NAME_PATTERN}, tags = {"file name", "pattern", "format"}},

	// Shortcuts: in the order of the tray's menu (Shortcut_Action's)
	{name = "shortcut.screen", title = i18n.later("Capture the screen"), description = i18n.later("Capture the whole screen under the pointer."), kind = .String, default = {s = "Print"}, tags = {"hotkey", "keybinding", "keys", "monitor", "full screen", "print screen"}},
	{name = "shortcut.region", title = i18n.later("Capture a region"), description = i18n.later("Capture a region: drag a rectangle, click a window framed, or take a screen, on the frozen screen."), kind = .String, default = {s = "Ctrl+Print"}, tags = {"hotkey", "keybinding", "keys", "selection", "print screen"}},
	{name = "shortcut.record", title = i18n.later("Record a video"), description = i18n.later("Choose a region to record as a video, then press Record. The same keys start the recording, then stop it."), kind = .String, default = {s = "Shift+Print"}, tags = {"hotkey", "keybinding", "keys", "video", "mp4", "screencast"}},
	{name = "shortcut.record_gif", title = i18n.later("Record a GIF"), description = i18n.later("Choose a region to record as a GIF, then press Record. The same keys start the recording, then stop it."), kind = .String, default = {s = "Ctrl+Shift+Print"}, tags = {"hotkey", "keybinding", "keys", "gif", "animation", "screencast"}},
	{name = "shortcut.window", title = i18n.later("Capture the window in front"), description = i18n.later("Capture the window in front."), kind = .String, default = {s = "Alt+Print"}, tags = {"hotkey", "keybinding", "keys", "active window", "print screen"}},
	{name = "shortcut.ocr", title = i18n.later("Read the text"), description = i18n.later("Read the text in a region: it goes to the clipboard."), kind = .String, default = {s = "Ctrl+Alt+T"}, tags = {"hotkey", "keybinding", "keys", "ocr", "text"}},
	{name = "shortcut.qr", title = i18n.later("Read a QR code"), description = i18n.later("Read a QR code in a region: its text goes to the clipboard."), kind = .String, default = {s = "Ctrl+Alt+Q"}, tags = {"hotkey", "keybinding", "keys", "barcode", "scan"}},
}

// What a click on the tray icon does (general.tray_click).
Tray_Click :: enum u8 { Region, Screen, Window, Qr, Ocr, Record, History, Settings }

TRAY_CLICK_NAMES := [Tray_Click]string{.Region = "region", .Screen = "screen", .Window = "window", .Qr = "qr", .Ocr = "ocr", .Record = "record", .History = "history", .Settings = "settings"}

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	menu, autostart:    bool,
	tray_click:         Tray_Click,
	appearance:         prefs_page.Appearance,   // appearance.theme, mode, finish, font_size (theme owned)
	delay_s:            int,
	record_fps, gif_fps, gif_width, record_max_s: int,
	record_cursor:      bool,
	history_size:       int,
	history_view:       History_View_Mode,
	history_thumbnail:  int,
	history_preview_em: f32,   // the preview pane's width, ems (history.preview_width: its splitter sets it)
	ocr_languages:      string,
	confirm_on_release: bool,
	frame_windows:      bool,
	magnifier:          bool,
	dim:                f32,   // 0..1
	record_notify:      bool,
	record_reveal:      bool,
	uploader:           string,   // the default host of an Upload step
	folder:             string,   // the default folder of a Save step ("": save_folder_default)
	name_pattern:       string,   // the default name of a Save step
	shortcuts:          [Shortcut_Action]string,   // as platform.hotkey_parse reads them; "": none
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/prefs"}, allocator)
}

// The user's own themes, beside the preferences (prefs_page.Themes_File).
themes_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/themes.txt"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	prefs_register(p)
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

// The toolkit's standard sets cliche takes: all but the updates (a package manager or a release's archive updates it).
STANDARD_SETS :: prefs_page.Standard{.Appearance, .Text, .Scrolling, .Input, .Timing, .Rendering, .Session}

// The toolkit's standard preferences, then cliche's own.
prefs_register :: proc(p: ^config.Prefs) {
	d := prefs_page.STANDARD_DEFAULTS   // (the toolkit's defaults for the rest: system mode, machined, 14 px)
	d.theme, d.app_name = "cliche", APP_NAME
	d.system_title = true   // (cliche's windows have the system's title bar)
	prefs_page.standard_register(p, STANDARD_SETS, d)
	config.register(p, PREF_DEFS[:])
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.menu = config.bool_of(p, "general.menu")
	s.autostart = config.bool_of(p, "general.autostart")
	click := config.string_of(p, "general.tray_click")
	for name, c in TRAY_CLICK_NAMES { if name == click { s.tray_click = c } }
	s.appearance = prefs_page.appearance_read(p, allocator)
	s.delay_s = int(config.int_of(p, "capture.delay"))
	s.record_fps = int(config.int_of(p, "record.fps"))
	s.gif_fps = int(config.int_of(p, "record.gif_fps"))
	s.gif_width = int(config.int_of(p, "record.gif_width"))
	s.record_max_s = int(config.int_of(p, "record.max_length"))
	s.record_cursor = config.bool_of(p, "record.cursor")
	s.history_size, s.history_view, s.history_thumbnail, s.history_preview_em = history_settings_read(p)
	s.ocr_languages = strings.clone(strings.trim_space(config.string_of(p, "capture.ocr_languages")), allocator)
	s.confirm_on_release = config.bool_of(p, "region.confirm_on_release")
	s.frame_windows = config.bool_of(p, "region.frame_windows")
	s.magnifier = config.bool_of(p, "region.magnifier")
	s.dim = f32(config.int_of(p, "region.dim")) / 100
	s.record_notify = config.bool_of(p, "record.notify")
	s.record_reveal = config.bool_of(p, "record.reveal")
	s.uploader = strings.clone(config.string_of(p, "upload.uploader"), allocator)
	s.folder = strings.clone(strings.trim_space(config.string_of(p, "save.folder")), allocator)
	s.name_pattern = strings.clone(config.string_of(p, "save.name"), allocator)
	for pref, a in SHORTCUT_PREFS { s.shortcuts[a] = strings.clone(strings.trim_space(config.string_of(p, pref)), allocator) }
	return
}

settings_free :: proc(s: ^Settings, allocator := context.allocator) {
	prefs_page.appearance_destroy(&s.appearance)
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

// What a crash report says of the preferences: the user's changes as their file has them, kept as text when they change,
// because the crash handler may neither allocate nor lock: it only copies this.
CRASH_SETTINGS_BYTES :: 8192

Crash_Settings :: struct {
	text: [CRASH_SETTINGS_BYTES]u8,
	size: int,   // (atomic)
}

crash_settings_keep :: proc(c: ^Crash_Settings, p: ^config.Prefs) {
	text := config.export(p, .Own, allocator = context.temp_allocator)
	sync.atomic_store(&c.size, 0)   // (a crash meanwhile says nothing rather than half of two texts)
	n := copy(c.text[:], text)
	sync.atomic_store(&c.size, n)
}

crash_settings_text :: proc "contextless" (user: rawptr, buf: []u8) -> int {
	c := (^Crash_Settings)(user)
	n := min(sync.atomic_load(&c.size), len(buf))
	return copy(buf[:n], c.text[:n])
}
