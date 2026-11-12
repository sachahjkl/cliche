package cliche

// The settings: a window of its own with gui_toolkit's page of the preferences (gt:prefs_page). Made at its first show,
// then hidden at a close and shown again. Each change is applied at once and written by the worker (app_prefs_changed).

import "core:fmt"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:ui"

SETTINGS_SIZE :: [2]int{820, 560}

Settings_Window :: struct {
	host:      host.Host,
	opened:    bool,
	visible:   bool,
	hide_due:  bool,   // a close or Escape came in a frame: the window goes after it (not from inside it)
	page:      prefs_page.Page,
	icons:     font.Font_Id,
}

@(private = "file", rodata)
SETTINGS_PAGES := [?]prefs_page.Page_Info{
	{category = "save",      title = "Save",      icon = lucide.SAVE},
	{category = "after",     title = "After capture", icon = lucide.COPY},
	{category = "region",    title = "Region",    icon = lucide.IMAGE},
	{category = "shortcuts", title = "Shortcuts", icon = lucide.KEYBOARD},
}

settings_window_show :: proc(app: ^App) {
	sw := &app.settings_window
	if !sw.opened {
		if !host.host_open(&sw.host, &app.shared, {title = "cliche settings", size = SETTINGS_SIZE}, settings_build, app) {
			fmt.eprintln("cliche: the settings window cannot open")
			return
		}
		sw.opened = true
		sw.host.input = settings_input
		sw.host.after_input = 3
		sw.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
		sw.host.state.icon_font = sw.icons
		app_wake_set(app, .Settings, sw.host.win)
	}
	token := app_take_token(app)
	defer delete(token)
	if !sw.visible {
		host.host_show(&sw.host)
		sw.visible = true
		prefs_page.focus_search(&sw.page)
	}
	platform.raise_window_token(sw.host.win, token)
	sw.host.settle = max(sw.host.settle, 3)
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
	app_hotkeys_follow(app)
	if ui.key_press(.Escape) && !prefs_page.editing(&sw.page) { sw.hide_due = true }
	if SHORTCUTS_NOTE != "" { ui.label(SHORTCUTS_NOTE) }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&sw.page, &app.prefs, settings_options(app))
}

@(private = "file")
settings_options :: proc(app: ^App) -> prefs_page.Options {
	return {
		user = app,
		changed = proc(user: rawptr, name: string) { app_prefs_changed((^App)(user)) },
		hotkeys = HOTKEY_PREF_NAMES[:],
		problem = proc(user: rawptr, name: string) -> string { return hotkey_problem((^App)(user), name) },
		pages = SETTINGS_PAGES[:], icon_font = app.settings_window.icons, search_icon = lucide.SEARCH, reset_icon = lucide.REFRESH_CW,
		foot = "prefs: " + APP_NAME + "/prefs in the configuration folder",
		version = "cliche " + APP_VERSION,
	}
}

settings_after_frame :: proc(app: ^App) {
	sw := &app.settings_window
	if !sw.hide_due { return }
	sw.hide_due = false
	host.host_hide(&sw.host)
	sw.visible = false
}

settings_window_free :: proc(app: ^App) {
	prefs_page.destroy(&app.settings_window.page)
}
