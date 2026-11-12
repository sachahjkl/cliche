package cliche

// The settings: a window of its own with gui_toolkit's page of the preferences (gt:prefs_page), in the theme of
// appearance.theme, with the command palette (Ctrl+K: cliche's actions, then every setting) and the sheet of its keys
// (F1). Made at its first show, then hidden at a close and shown again. Each change is applied at once and written by
// the worker (app_prefs_changed). What is slow (a folder chosen, a folder opened) goes to the worker too.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import config "gt:config"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import shortcuts "gt:shortcuts"
import "gt:ui"

SETTINGS_SIZE :: [2]int{880, 620}

Settings_Window :: struct {
	host:        host.Host,
	opened:      bool,
	visible:     bool,
	hide_due:    bool,   // a close or Escape came in a frame: the window goes after it (not from inside it)
	page:        prefs_page.Page,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	palette:     ui.Command_Palette,
	sheet_open:  bool,
	copied:      string,   // the command whose Copy was pressed last (its button says so); static text
}

@(rodata)
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "general",    title = "General",       icon = lucide.SETTINGS},
	{category = "appearance", title = "Appearance",    icon = lucide.PALETTE},
	{category = "shortcuts",  title = "Shortcuts",     icon = lucide.KEYBOARD},
	{category = "capture",    title = "Capture",       icon = lucide.MONITOR},
	{category = "region",     title = "Region",        icon = lucide.IMAGE},
	{category = "record",     title = "Recording",     icon = lucide.MONITOR},
	{category = "after",      title = "After capture", icon = lucide.CLIPBOARD},
	{category = "save",       title = "Save",          icon = lucide.SAVE},
	{category = "upload",     title = "Upload",        icon = lucide.EXTERNAL_LINK},
}

// The preferences with a control of cliche's own, under their words.
@(rodata)
SETTINGS_CUSTOM := [?]string{"appearance.theme"}

// The actions of the palette and of the sheet of keys.
Settings_Action :: enum u8 {
	Capture_Region, Capture_Screen, Capture_Window, Read_Qr, Read_Text, Record, Record_Gif,
	Choose_Folder, Open_Folder, Open_Uploaders, Import_Uploader, Shortcuts_Page, System_Shortcuts,
	Palette, Keys, Close, Quit,
}

SETTINGS_ACTIONS := [Settings_Action]ui.Command{
	.Capture_Region   = {label = "Capture a region", group = "Capture", icon = lucide.IMAGE, tags = {"screenshot", "rectangle", "selection"}},
	.Capture_Screen   = {label = "Capture the screen under the pointer", group = "Capture", icon = lucide.MONITOR, tags = {"screenshot", "monitor", "full"}},
	.Capture_Window   = {label = "Capture the window in front", group = "Capture", icon = lucide.IMAGE, tags = {"screenshot", "active"}},
	.Read_Qr          = {label = "Read a QR code", group = "Capture", icon = lucide.QR_CODE, tags = {"scan", "barcode"}},
	.Read_Text        = {label = "Read the text", group = "Capture", icon = lucide.CLIPBOARD, tags = {"ocr", "recognition", "copy"}},
	.Record           = {label = "Record a video (again: stop)", group = "Record", icon = lucide.MONITOR, tags = {"mp4", "screencast", "video"}},
	.Record_Gif       = {label = "Record a GIF (again: stop)", group = "Record", icon = lucide.IMAGE, tags = {"gif", "animation", "screencast"}},
	.Choose_Folder    = {label = "Choose the save folder…", group = "Save", icon = lucide.FOLDER, tags = {"directory", "where", "browse"}},
	.Open_Folder      = {label = "Open the save folder", group = "Save", icon = lucide.FOLDER_OPEN, tags = {"files", "explorer", "screenshots"}},
	.Open_Uploaders   = {label = "Open the uploaders' folder", group = "Upload", icon = lucide.FOLDER_OPEN, tags = {"sxcu", "sharex", "host"}},
	.Import_Uploader  = {label = "Import a ShareX uploader…", group = "Upload", icon = lucide.EXTERNAL_LINK, tags = {"sxcu", "sharex", "host", "add"}},
	.Shortcuts_Page   = {label = "Shortcuts", group = "Settings", icon = lucide.KEYBOARD, tags = {"hotkey", "keys", "keybinding"}},
	.System_Shortcuts = {label = "The system's shortcut settings…", group = "Settings", icon = lucide.EXTERNAL_LINK, tags = {"hotkey", "portal", "keys"}},
	.Palette          = {label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND, tags = {"actions", "search"}},
	.Keys             = {label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}, {}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}},
	.Close            = {label = "Close the settings", group = "Window", keys = {{.W, {.Ctrl}}, {}}, icon = lucide.X, tags = {"hide"}},
	.Quit             = {label = "Quit cliche", group = "Window", keys = {{.Q, {.Ctrl}}, {}}, icon = lucide.POWER, tags = {"exit", "stop"}},
}

settings_window_show :: proc(app: ^App) {
	sw := &app.settings_window
	if !sw.opened && !settings_window_open(app, headless = false) { return }
	token := app_take_token(app)
	defer delete(token)
	if !sw.visible {
		host.host_show(&sw.host)
		sw.visible = true
		prefs_page.focus_search(&sw.page)
		// (the uploaders' folder may have changed since: its list is read again on the worker)
		worker_send(&app.worker, Job_Uploaders{})
	}
	platform.raise_window_token(sw.host.win, token)
	sw.host.settle = max(sw.host.settle, 3)
}

// Opens the window (hidden). `headless`: offscreen, on the software renderer (shots.odin).
settings_window_open :: proc(app: ^App, headless: bool) -> bool {
	sw := &app.settings_window
	if !host.host_open(&sw.host, &app.shared, {title = "cliche settings", size = SETTINGS_SIZE, headless = headless}, settings_build, app) {
		fmt.eprintln("cliche: the settings window cannot open")
		return false
	}
	sw.opened = true
	sw.host.input = settings_input
	sw.host.params = settings_params
	sw.host.after_input = 3
	sw.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	sw.host.state.icon_font = sw.icons
	app_wake_set(app, .Settings, sw.host.win)
	return true
}

// Each build: the theme (applied only when it changes, or when the system goes light or dark), the base style.
@(private = "file")
settings_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	sw := &app.settings_window
	s := &app.settings
	choice := ui.Theme_Choice{name = s.theme, mode = s.mode, finish = s.finish, glow = 1}
	if ui.theme_show(&app.shared.theme, themes(), choice, &sw.theme_shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !sw.theme_shown.light)
	}
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = s.font_size, text_pad = 6, cursor = .Arrow}
}

@(private = "file")
settings_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		if e.kind == .Close {
			platform.cancel_close(h.win)
			app.settings_window.hide_due = true
			continue
		}
		append(&out, e)
	}
	return out[:]
}

@(private = "file")
settings_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	sw := &app.settings_window
	app_shortcuts_recording(app)
	dialog := sw.palette.open || sw.sheet_open
	if !dialog && !prefs_page.editing(&sw.page) {
		if ui.key_press(.Escape) { sw.hide_due = true }
		for a in Settings_Action {
			if ui.command_pressed(SETTINGS_ACTIONS[a], settings_action_enabled(app, a)) { settings_action(app, a); break }
		}
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&sw.page, &app.prefs, settings_options(app))
	settings_dialogs(app)
}

// The palette (cliche's actions, then every setting: one chosen shows the settings on it alone) and the sheet of keys.
@(private = "file")
settings_dialogs :: proc(app: ^App) {
	sw := &app.settings_window
	actions := slice.enumerated_array(&SETTINGS_ACTIONS)
	if sw.palette.open {
		o := settings_options(app)
		settings, names := prefs_page.palette_commands(&app.prefs, o)
		all := slice.concatenate([][]ui.Command{actions, settings}, context.temp_allocator)
		enabled := make([]bool, len(all), context.temp_allocator)
		for a in Settings_Action { enabled[int(a)] = settings_action_enabled(app, a) }
		for i in len(actions) ..< len(all) { enabled[i] = true }
		if i, _ := ui.palette(&sw.palette, all, enabled); i >= 0 {
			if i < len(actions) { settings_action(app, Settings_Action(i)) } else { prefs_page.show(&sw.page, &app.prefs, o, names[i - len(actions)]) }
		}
	}
	ui.shortcuts_sheet("keys", actions, &sw.sheet_open, "cliche's keys")
}

@(private = "file")
settings_action_enabled :: proc(app: ^App, a: Settings_Action) -> bool {
	#partial switch a {
	case .System_Shortcuts: return shortcuts.can_configure(app.shortcuts)
	}
	return true
}

@(private = "file")
settings_action :: proc(app: ^App, a: Settings_Action) {
	sw := &app.settings_window
	switch a {
	case .Capture_Region:   sw.hide_due = true; app_trigger(app, .Region)
	case .Capture_Screen:   sw.hide_due = true; app_trigger(app, .Screen)
	case .Capture_Window:   sw.hide_due = true; app_trigger(app, .Window)
	case .Read_Qr:          sw.hide_due = true; app_trigger(app, .Region, .Qr)
	case .Read_Text:        sw.hide_due = true; app_trigger(app, .Region, .Text)
	case .Record:           sw.hide_due = true; app_record_trigger(app, .Mp4)
	case .Record_Gif:       sw.hide_due = true; app_record_trigger(app, .Gif)
	case .Choose_Folder:    worker_send(&app.worker, Job_Pick_Folder{start = strings.clone(app.settings.folder)})
	case .Open_Folder:      worker_send(&app.worker, Job_Open_Folder{folder = strings.clone(app.settings.folder)})
	case .Open_Uploaders:   worker_send(&app.worker, Job_Open_Folder{folder = strings.clone(uploaders_folder())})
	case .Import_Uploader:  worker_send(&app.worker, Job_Import_Uploader{})
	case .Shortcuts_Page:
		delete(sw.page.current)
		sw.page.current = strings.clone("shortcuts")
	case .System_Shortcuts: shortcuts.configure(app.shortcuts)
	case .Palette:          ui.palette_open(&sw.palette)
	case .Keys:             sw.sheet_open = true
	case .Close:            sw.hide_due = true
	case .Quit:             app.quit = true
	}
}

settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app,
		changed = proc(user: rawptr, name: string) { app_prefs_changed((^App)(user)) },
		choices = settings_choices,
		custom_names = SETTINGS_CUSTOM[:], custom = settings_custom,
		hotkeys = SHORTCUT_PREF_NAMES[:],
		status = settings_status,
		problem = proc(user: rawptr, name: string) -> string { return shortcut_problem((^App)(user), name) },
		page_foot = settings_page_foot,
		pages = SETTINGS_PAGES[:], icon_font = app.settings_window.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		foot = "prefs: " + APP_NAME + "/prefs in the configuration folder",
		version = "cliche " + APP_VERSION,
	}
}

// The words of a choice the registry keeps as a short value.
@(private = "file")
settings_choices :: proc(user: rawptr, name: string) -> (labels, values: []string) {
	switch name {
	case "general.tray_click":
		@(static, rodata) l := [?]string{"Capture a region", "Capture the screen", "Capture the window", "Read a QR code", "Read the text", "Record a video", "Open the settings"}
		@(static, rodata) v := [?]string{"region", "screen", "window", "qr", "ocr", "record", "settings"}
		return l[:], v[:]
	case "upload.uploader":
		names := app_of(user).uploaders.names
		if len(names) == 0 { return }
		return names, names
	case "save.compression":
		@(static, rodata) l := [?]string{"Small files", "Fast saves"}
		@(static, rodata) v := [?]string{"small", "fast"}
		return l[:], v[:]
	}
	return
}

// The themes as cards, each in its own colours.
@(private = "file")
settings_custom :: proc(user: rawptr, name: string, em: f32) {
	app := (^App)(user)
	if name != "appearance.theme" { return }
	list := themes()
	if at := prefs_page.theme_cards(list, app.settings.theme, app.settings_window.theme_shown.light, em); at >= 0 {
		if config.set_from_string(&app.prefs, "appearance.theme", list[at].name, .User) == .None { app_prefs_changed(app) }
	}
}

// What a line says of its preference's state: a shortcut's keys, the name the next file gets, the folder used.
@(private = "file")
settings_status :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	switch name {
	case "save.name":
		// (an example date: the local time needs the time zone's file, which the interface's thread does not read)
		example := Stamp{year = 2026, month = 3, day = 7, hour = 9, minute = 5, second = 4, milli = 42}
		return fmt.tprintf("For example: %s", name_expand(app.settings.name_pattern, example, .Region, context.temp_allocator))
	case "save.folder":
		if app.settings.folder == "" && app.default_folder != "" { return fmt.tprintf("Now: %s", app.default_folder) }
		return ""
	}
	return shortcut_status(app, name)
}

// Under a page: the save folder's buttons; the shortcuts' system settings and commands.
@(private = "file")
settings_page_foot :: proc(user: rawptr, category: string, em: f32) {
	app := (^App)(user)
	switch category {
	case "save":
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###save_buttons") {
			if foot_button("Choose a folder…###choose", em) { settings_action(app, .Choose_Folder) }
			ui.spacer(ui.px(em * 0.5))
			if foot_button("Open the folder###open", em) { settings_action(app, .Open_Folder) }
		}
	case "shortcuts":
		shortcuts_foot(app, em)
	case "upload":
		upload_foot(app, em)
	}
}

@(private = "file")
shortcuts_foot :: proc(app: ^App, em: f32) {
	sw := &app.settings_window
	ui.spacer(ui.px(em * 0.8))
	switch shortcuts.backend(app.shortcuts) {
	case .Portal:
		foot_text("The desktop keeps cliche's shortcuts while cliche runs. It may ask you to confirm them, and you may change the keys in its own settings.", em)
		if shortcuts.can_configure(app.shortcuts) {
			ui.spacer(ui.px(em * 0.5))
			if foot_button("The system's shortcut settings…###system", em) { settings_action(app, .System_Shortcuts) }
		}
	case .Windows:
		foot_text("Windows gives these keys to cliche in every program. Keys that another program holds cannot be used.", em)
	case .None:
		foot_text("This desktop gives programs no shortcuts of their own. Bind keys to these commands in its settings (Hyprland: bind = , Print, exec, cliche --region; sway: bindsym Print exec cliche --region):", em)
	}
	ui.spacer(ui.px(em * 0.6))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 1.5), font_size = math.round(em * 0.78), text_pad = 0})
		ui.label("COMMANDS###cmd_head")
	}
	for a in Shortcut_Action {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), axis = .X, cross = .Center})
		if ui.row(id = fmt.tprintf("###cmd%d", int(a))) {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###what", SHORTCUT_TEXT[a]))
			ui.next({width = ui.text_size(em * 0.8), height = ui.pct(1), font = ui.mono_font(), text_pad = 0})
			if ui.tags("weak") { ui.label(fmt.tprintf("%s###cmd", SHORTCUT_COMMANDS[a])) }
			ui.spacer(ui.px(em * 0.6))
			done := sw.copied == SHORTCUT_COMMANDS[a]
			ui.next({width = ui.px(em * 5.5), height = ui.px(math.round(em * 1.7)), radius = em * 0.35, font_size = math.round(em * 0.86)})
			sig: ui.Signal
			if ui.tags("ghost_button") { sig = ui.button(done ? "Copied###copy" : "Copy###copy") }
			if sig.clicked {
				platform.clipboard_set(sw.host.win, {text = SHORTCUT_COMMANDS[a]})
				sw.copied = SHORTCUT_COMMANDS[a]
			}
		}
	}
}

@(private = "file")
upload_foot :: proc(app: ^App, em: f32) {
	ui.spacer(ui.px(em * 0.8))
	foot_text("Add a host: put its ShareX uploader (.sxcu) in the uploaders' folder, or import it. The list above shows them.", em)
	for p in app.uploaders.problems {
		if ui.tags("bad") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###up_problem", p))
		}
	}
	if app.uploaders.import_problem != "" {
		if ui.tags("bad") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###import_problem", app.uploaders.import_problem))
		}
	}
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###upload_buttons") {
		if foot_button("Import a .sxcu file…###import", em) { settings_action(app, .Import_Uploader) }
		ui.spacer(ui.px(em * 0.5))
		if foot_button("Open the uploaders' folder###uploaders", em) { settings_action(app, .Open_Uploaders) }
	}
}

@(private = "file")
app_of :: proc(user: rawptr) -> ^App { return (^App)(user) }

@(private = "file")
foot_text :: proc(text: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.86), text_pad = 0})
		ui.paragraph(fmt.tprintf("%s###foot_text", text))
	}
}

// A button as wide as its words.
@(private = "file")
foot_button :: proc(label: string, em: f32) -> bool {
	ui.next({width = ui.text_size(em * 0.9), height = ui.px(math.round(em * 2)), radius = em * 0.4})
	return ui.button(label).clicked
}

settings_after_frame :: proc(app: ^App) {
	sw := &app.settings_window
	if !sw.hide_due { return }
	sw.hide_due = false
	sw.palette.open = false
	sw.sheet_open = false
	host.host_hide(&sw.host)
	sw.visible = false
}

settings_window_free :: proc(app: ^App) {
	prefs_page.destroy(&app.settings_window.page)
	ui.palette_destroy(&app.settings_window.palette)
}
