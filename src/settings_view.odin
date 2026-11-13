package cliche

// The settings: a mode of the main window (history_view.odin), in place of the history, with gui_toolkit's page of the
// preferences (gt:prefs_page). The gear of the history's toolbar and Ctrl+, open it; the back bar and Escape go back.
// The window's palette (Ctrl+K) holds cliche's actions, then every setting; its sheet of keys (F1) covers both modes.
// Each change is applied at once and written by the worker (app_prefs_changed). What is slow (a folder chosen, a folder
// opened) goes to the worker too.
//
// What is the toolkit's: the standard preferences (the look, the text, scrolling, input, the delays, rendering, the
// session: gui_toolkit docs/settings.md), the theme cards and the user's own themes file, the lines of the shortcuts (the
// keys recorded, what the system said), the settings file, export and import. What is cliche's: the pages, the words of
// its choices, the lines under the save folder's name and the file name, and what is under the pages (the licence, the
// folder, the uploaders, the commands).

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import shortcuts "gt:shortcuts"
import "gt:ui"
import i18n "gt:i18n"

// The settings' part of the main window.
Settings_Mode :: struct {
	open:   bool,
	page:   prefs_page.Page,
	copied: string,   // the command whose Copy was pressed last (its button says so); static text
}

SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "general",    title = i18n.later("General"),       icon = lucide.SETTINGS},
	{category = "appearance", title = i18n.later("Appearance"),    icon = lucide.PALETTE},
	{category = "shortcut",   title = i18n.later("Shortcuts"),     icon = lucide.KEYBOARD},
	{category = "capture",    title = i18n.later("Capture"),       icon = lucide.MONITOR},
	{category = "region",     title = i18n.later("Region"),        icon = lucide.IMAGE},
	{category = "record",     title = i18n.later("Recording"),     icon = lucide.FILM},
	{category = "save",       title = i18n.later("Save"),          icon = lucide.SAVE},
	{category = "upload",     title = i18n.later("Upload"),        icon = lucide.EXTERNAL_LINK},
	{category = "history",    title = i18n.later("History"),       icon = lucide.HISTORY},
	// (the toolkit's standard groups: the same pages in every program, after cliche's own)
	{category = "window",     title = i18n.later("Window"),        icon = lucide.APP_WINDOW},
	{category = "scrolling",  title = i18n.later("Scrolling"),     icon = lucide.ARROW_DOWN_UP},
	{category = "input",      title = i18n.later("Input"),         icon = lucide.MOUSE},
	{category = "timing",     title = i18n.later("Delays and menus"), icon = lucide.TIMER},
	{category = "rendering",  title = i18n.later("Rendering"),     icon = lucide.CPU},
}

// The actions of the palette and of the sheet of keys that the history's (History_Action) do not hold already.
Settings_Action :: enum u8 {
	Capture_Screen, Capture_Window, Read_Qr, Read_Text, Record, Record_Gif,
	Choose_Folder, Open_Uploaders, Import_Uploader, Shortcuts_Page, System_Shortcuts,
}

SETTINGS_ACTIONS := [Settings_Action]ui.Command{
	.Capture_Screen   = {label = i18n.later("Capture the screen under the pointer"), group = i18n.later("Capture"), icon = lucide.MONITOR, tags = {"screenshot", "monitor", "full"}},
	.Capture_Window   = {label = i18n.later("Capture the window in front"), group = i18n.later("Capture"), icon = lucide.IMAGE, tags = {"screenshot", "active"}},
	.Read_Qr          = {label = i18n.later("Read a QR code"), group = i18n.later("Capture"), icon = lucide.QR_CODE, tags = {"scan", "barcode"}},
	.Read_Text        = {label = i18n.later("Read the text"), group = i18n.later("Capture"), icon = lucide.CLIPBOARD, tags = {"ocr", "recognition", "copy"}},
	.Record           = {label = i18n.later("Record a video"), group = i18n.later("Record"), icon = lucide.FILM, tags = {"mp4", "screencast", "video"}},
	.Record_Gif       = {label = i18n.later("Record a GIF"), group = i18n.later("Record"), icon = lucide.FILM, tags = {"gif", "animation", "screencast"}},
	.Choose_Folder    = {label = i18n.later("Choose the save folder…"), group = i18n.later("Save"), icon = lucide.FOLDER, tags = {"directory", "where", "browse"}},
	.Open_Uploaders   = {label = i18n.later("Open the uploaders' folder"), group = i18n.later("Upload"), icon = lucide.FOLDER_OPEN, tags = {"sxcu", "sharex", "host"}},
	.Import_Uploader  = {label = i18n.later("Import a ShareX uploader…"), group = i18n.later("Upload"), icon = lucide.EXTERNAL_LINK, tags = {"sxcu", "sharex", "host", "add"}},
	.Shortcuts_Page   = {label = i18n.later("Shortcuts"), group = i18n.later("Settings"), icon = lucide.KEYBOARD, tags = {"hotkey", "keys", "keybinding"}},
	.System_Shortcuts = {label = i18n.later("The system's shortcut settings…"), group = i18n.later("Settings"), icon = lucide.EXTERNAL_LINK, tags = {"hotkey", "portal", "keys"}},
}

// `cliche --settings`, the tray's Settings: the main window, shown, in settings mode.
settings_show :: proc(app: ^App) {
	history_window_show(app)
	settings_enter(app)
}

// The main window goes to the settings (it is shown already, or about to be).
settings_enter :: proc(app: ^App) {
	m := &app.history_window.settings_mode
	if m.open { return }
	workflow_mode_leave(app)
	m.open = true
	prefs_page.focus_search(&m.page)
	// (the uploaders' folder may have changed since: its list is read again on the worker)
	worker_send(&app.worker, Job_Uploaders{})
}

// Back to the history.
settings_leave :: proc(app: ^App) {
	app.history_window.settings_mode.open = false
}

// The keys of the settings' mode (no dialog open): Escape goes back when no preference has the keyboard; the window's
// own commands (the palette, the sheet, close, quit) are the history's (history_view.odin).
settings_keys :: proc(app: ^App) {
	m := &app.history_window.settings_mode
	if prefs_page.escape_leaves(&m.page) { settings_leave(app) }
}

// The settings' mode of the main window: the back bar, then the page.
settings_build :: proc(app: ^App, em: f32) {
	m := &app.history_window.settings_mode
	o := settings_options(app)
	if prefs_page.back_bar(&m.page, o, i18n.tr("Settings"), i18n.tr("Back to the history (Escape)"), em) { settings_leave(app) }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&m.page, &app.prefs, o)
}

// The palette's part of the settings: cliche's actions the history lacks, then every preference (`names`: the
// preferences' names, in their order after the actions).
settings_palette :: proc(app: ^App) -> (commands: []ui.Command, enabled: []bool, names: []string) {
	actions := slice.enumerated_array(&SETTINGS_ACTIONS)
	prefs, pref_names := prefs_page.palette_commands(&app.prefs, settings_options(app))
	commands = slice.concatenate([][]ui.Command{actions, prefs}, context.temp_allocator)
	enabled = make([]bool, len(commands), context.temp_allocator)
	for a in Settings_Action { enabled[int(a)] = settings_action_enabled(app, a) }
	for i in len(actions) ..< len(commands) { enabled[i] = true }
	return commands, enabled, pref_names
}

// The palette's choice `i` in settings_palette's list: an action, or a preference shown alone on the settings.
settings_palette_chosen :: proc(app: ^App, i: int, names: []string) {
	if i < len(Settings_Action) { settings_action(app, Settings_Action(i)); return }
	settings_enter(app)
	m := &app.history_window.settings_mode
	prefs_page.show(&m.page, &app.prefs, settings_options(app), names[i - len(Settings_Action)])
}

settings_action_enabled :: proc(app: ^App, a: Settings_Action) -> bool {
	#partial switch a {
	case .System_Shortcuts: return shortcuts.can_configure(app.shortcuts)
	}
	return true
}

settings_action :: proc(app: ^App, a: Settings_Action) {
	hw := &app.history_window
	switch a {
	case .Capture_Screen:   hw.hide_due = true; app_trigger(app, .Screen)
	case .Capture_Window:   hw.hide_due = true; app_trigger(app, .Window)
	case .Read_Qr:          hw.hide_due = true; app_trigger(app, .Qr)
	case .Read_Text:        hw.hide_due = true; app_trigger(app, .Ocr)
	case .Record:           hw.hide_due = true; app_record_trigger(app, .Mp4)
	case .Record_Gif:       hw.hide_due = true; app_record_trigger(app, .Gif)
	case .Choose_Folder:    app_pick_folder(app, app.settings.folder)
	case .Open_Uploaders:   worker_send(&app.worker, Job_Open_Folder{folder = strings.clone(uploaders_folder())})
	case .Import_Uploader:  app_import_uploader(app)
	case .Shortcuts_Page:
		settings_enter(app)
		delete(hw.settings_mode.page.current)
		hw.settings_mode.page.current = strings.clone("shortcut")
	case .System_Shortcuts: shortcuts.configure(app.shortcuts)
	}
}

settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app,
		changed = proc(user: rawptr, name: string) { app_prefs_changed((^App)(user)) },
		choices = settings_choices,
		themes = app.themes_file.all[:], themes_file = &app.themes_file,
		shortcuts = app.shortcuts,
		themes_light = app.history_window.theme_shown.light,
		shortcut_prefs = slice.enumerated_array(&SHORTCUT_PAGE_PREFS),
		status = settings_status,
		page_foot = settings_page_foot,
		pages = SETTINGS_PAGES[:], icon_font = app.history_window.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		file = prefs_file(),
		version = "cliche " + APP_VERSION,
	}
}

settings_mode_free :: proc(app: ^App) {
	prefs_page.destroy(&app.history_window.settings_mode.page)
}

// The words of a choice the registry keeps as a short value.
@(private = "file")
settings_choices :: proc(user: rawptr, name: string) -> (labels, values: []string) {
	switch name {
	case "general.tray_click":
		l := [?]string{i18n.later("Capture a region"), i18n.later("Capture the screen"), i18n.later("Capture the window"), i18n.later("Read a QR code"), i18n.later("Read the text"), i18n.later("Record a video"), i18n.later("Open the history"), i18n.later("Open the settings")}
		@(static, rodata) v := [?]string{"region", "screen", "window", "qr", "ocr", "record", "history", "settings"}
		@(static) shown: [len(l)]string
		return labels_shown(shown[:], l[:]), v[:]
	case "upload.uploader":
		names := app_of(user).uploaders.names
		if len(names) == 0 { return }
		return names, names
	case "history.view":
		l := [?]string{i18n.later("Grid"), i18n.later("List")}
		@(static, rodata) v := [?]string{"grid", "list"}
		@(static) shown: [len(l)]string
		return labels_shown(shown[:], l[:]), v[:]
	case "history.thumbnail_size":
		l := [?]string{i18n.later("Small"), i18n.later("Medium"), i18n.later("Large")}
		@(static, rodata) v := [?]string{"small", "medium", "large"}
		@(static) shown: [len(l)]string
		return labels_shown(shown[:], l[:]), v[:]
	}
	return
}

// What a line says of its preference's state: the name the next file gets, the folder used. (The shortcuts' lines are
// the toolkit's.)
@(private = "file")
settings_status :: proc(user: rawptr, name: string) -> string {
	app := (^App)(user)
	switch name {
	case "save.name":
		// (an example date: the local time needs the time zone's file, which the interface's thread does not read)
		example := Stamp{year = 2026, month = 3, day = 7, hour = 9, minute = 5, second = 4, milli = 42}
		return fmt.tprintf(i18n.tr("For example: %s"), name_expand(app.settings.name_pattern, example, .Region, context.temp_allocator))
	case "save.folder":
		if app.settings.folder == "" && app.default_folder != "" { return fmt.tprintf(i18n.tr("Now: %s"), app.default_folder) }
	}
	return ""
}

// Under a page: the licence; the save folder's buttons; the shortcuts' system settings and commands; the uploaders.
@(private = "file")
settings_page_foot :: proc(user: rawptr, category: string, em: f32) {
	app := (^App)(user)
	switch category {
	case "general":
		licence_section(app, em)
	case "save":
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###save_buttons") {
			if foot_button(fmt.tprintf("%s###choose", i18n.tr("Choose a folder…")), em) { settings_action(app, .Choose_Folder) }
			ui.spacer(ui.px(em * 0.5))
			if foot_button(fmt.tprintf("%s###open", i18n.tr("Open the folder")), em) { worker_send(&app.worker, Job_Open_Folder{folder = strings.clone(app.settings.folder)}) }
		}
	case "shortcut":
		shortcuts_foot(app, em)
	case "upload":
		upload_foot(app, em)
	}
}

@(private = "file")
shortcuts_foot :: proc(app: ^App, em: f32) {
	m := &app.history_window.settings_mode
	ui.spacer(ui.px(em * 0.8))
	switch shortcuts.backend(app.shortcuts) {
	case .Portal:
		foot_text(i18n.tr("The desktop keeps cliche's shortcuts while cliche runs. It may ask you to confirm them, and you may change the keys in its own settings."), em)
		if shortcuts.can_configure(app.shortcuts) {
			ui.spacer(ui.px(em * 0.5))
			if foot_button(fmt.tprintf("%s###system", i18n.tr("The system's shortcut settings…")), em) { settings_action(app, .System_Shortcuts) }
		}
	case .Windows:
		foot_text(i18n.tr("Windows gives these keys to cliche in every program. Keys that another program holds cannot be used."), em)
	case .None:
		foot_text(i18n.tr("This desktop gives programs no shortcuts of their own. Bind keys to these commands in its settings (Hyprland: bind = CTRL, Print, exec, cliche --region; sway: bindsym Ctrl+Print exec cliche --region):"), em)
	}
	ui.spacer(ui.px(em * 0.6))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 1.5), font_size = math.round(em * 0.78), text_pad = 0})
		ui.label(fmt.tprintf("%s###cmd_head", i18n.tr("COMMANDS")))
	}
	for a in Shortcut_Action {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.1)), axis = .X, cross = .Center})
		if ui.row(id = fmt.tprintf("###cmd%d", int(a))) {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###what", i18n.tr(SHORTCUT_TEXT[a])))
			ui.next({width = ui.text_size(em * 0.8), height = ui.pct(1), font = ui.mono_font(), text_pad = 0})
			if ui.tags("weak") { ui.label(fmt.tprintf("%s###cmd", SHORTCUT_COMMANDS[a])) }
			ui.spacer(ui.px(em * 0.6))
			done := m.copied == SHORTCUT_COMMANDS[a]
			// (one width for both words: the row does not move when it says Copied)
			ui.next({font_size = math.round(em * 0.86)})
			if ui.button_icon("###copy", done ? lucide.CHECK : lucide.COPY, done ? i18n.tr("Copied") : i18n.tr("Copy"), width = ui.px(em * 6.5)).clicked {
				platform.clipboard_set(app.history_window.host.win, {text = SHORTCUT_COMMANDS[a]})
				m.copied = SHORTCUT_COMMANDS[a]
			}
		}
	}
}

@(private = "file")
upload_foot :: proc(app: ^App, em: f32) {
	ui.spacer(ui.px(em * 0.8))
	foot_text(i18n.tr("Add a host: put its ShareX uploader (.sxcu) in the uploaders' folder, or import it. The list above shows them."), em)
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
		if foot_button(fmt.tprintf("%s###import", i18n.tr("Import a .sxcu file…")), em) { settings_action(app, .Import_Uploader) }
		ui.spacer(ui.px(em * 0.5))
		if foot_button(fmt.tprintf("%s###uploaders", i18n.tr("Open the uploaders' folder")), em) { settings_action(app, .Open_Uploaders) }
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

// The words of a choice in the language in use, in `out` (static: the page may keep them past the frame).
@(private = "file")
labels_shown :: proc(out, english: []string) -> []string {
	for e, i in english { out[i] = i18n.tr(e) }
	return out
}

// A button as wide as its words.
@(private = "file")
foot_button :: proc(label: string, em: f32) -> bool {
	ui.next({width = ui.text_size(em * 0.9), height = ui.px(math.round(em * 2)), radius = em * 0.4})
	return ui.button(label).clicked
}
