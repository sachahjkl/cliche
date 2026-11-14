package cliche

import "core:slice"
import "core:strings"
import "core:testing"
import config "gt:config"
import "gt:ui"

// The palette opens in every mode of the main window, a field of the mode having the keyboard or not: its actions and
// the window's other ones are the window's (scope .Window), read in every mode by history_window_keys, and the toolkit
// takes their keys whatever has the focus. None types text, or a field would keep it.
@(test)
the_palette_opens_in_every_mode :: proc(t: ^testing.T) {
	for a in ([]History_Action{.Workflows, .Settings, .Palette, .Keys, .Close, .Quit}) {
		testing.expectf(t, HISTORY_ACTIONS[a].scope == .Window, "%v is the window's", a)
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&HISTORY_ACTIONS))), 0)
	for mode in History_Mode {
		for typing in ([2]bool{false, true}) {
			read := history_keys_read(mode, typing)
			testing.expectf(t, .Palette not_in read, "%v, typing %v: the palette is the window's, not the page's", mode, typing)
		}
	}
	// (the history's own actions on the settings would act on rows nobody sees)
	testing.expect(t, .Remove not_in history_keys_read(.Settings, false))
	testing.expect(t, .Remove in history_keys_read(.History, false))
	// the editor's: read before its guards (a shape's text typed, an export, a dialog)
	for a in Editor_Action {
		want := a == .Close || a == .Palette || a == .Keys
		testing.expectf(t, (EDITOR_ACTIONS[a].scope == .Window) == want, "the editor's %v: the window's is %v", a, want)
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&EDITOR_ACTIONS))), 0)
}

// In the settings mode the palette lists the window's commands and the settings themselves: a setting is reached
// from the palette.
@(test)
the_palette_lists_the_settings_in_the_settings_mode :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	prefs_register(&app.prefs)
	app.settings = prefs_read(&app.prefs)
	hw := &app.history_window
	defer {
		palette_table_destroy(&hw.palette_table)
		ui.views_commands_destroy(&hw.view_cmds)
		settings_free(&app.settings)
		config.prefs_destroy(&app.prefs)
	}
	settings_enter(app)
	commands := history_palette_commands(app)
	testing.expect(t, len(commands) > len(History_Action), "the settings are not in the palette")
	testing.expect_value(t, commands[int(History_Action.Palette)].label, HISTORY_ACTIONS[.Palette].label)
	// (history.size: "Captures kept", on the History page)
	found := false
	for c in commands {
		if c.label == "Captures kept" && strings.has_prefix(c.group, "Settings") { found = true }
	}
	testing.expect(t, found, "the setting \"Captures kept\" is not in the palette")
}
