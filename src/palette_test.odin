package cliche

import "core:slice"
import "core:testing"
import config "gt:config"
import "gt:ui"

// The window's commands are read in every mode of the main window, a field of the mode having the keyboard or not
// (scope .Window, history_window_keys), and the toolkit takes their keys whatever has the focus: none types text. The
// palette's own keys are the toolkit's (ui.palette_keys): no table has a line of it.
@(test)
the_window_commands_are_read_in_every_mode :: proc(t: ^testing.T) {
	for a in ([]History_Action{.Workflows, .Settings, .Keys, .About, .Close, .Quit}) {
		testing.expectf(t, HISTORY_ACTIONS[a].scope == .Window, "%v is the window's", a)
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&HISTORY_ACTIONS))), 0)
	for mode in History_Mode {
		for typing in ([2]bool{false, true}) {
			read := history_keys_read(mode, typing)
			testing.expectf(t, .Keys not_in read, "%v, typing %v: the sheet is the window's, not the page's", mode, typing)
		}
	}
	// (the history's own actions on the settings would act on rows nobody sees)
	testing.expect(t, .Remove not_in history_keys_read(.Settings, false))
	testing.expect(t, .Remove in history_keys_read(.History, false))
	// the editor's: read before its guards (a shape's text typed, an export, a dialog)
	for a in Editor_Action {
		want := a == .Close || a == .Keys
		testing.expectf(t, (EDITOR_ACTIONS[a].scope == .Window) == want, "the editor's %v: the window's is %v", a, want)
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&EDITOR_ACTIONS))), 0)
}

// The main window's palette has one table of prefixes, the toolkit's (gui_toolkit's src/md/features/palette.md): the
// commands (`>`, the views' moves beside them), the captures (`@`, go to one), the workflows (`#`, choose one) and the
// settings (`:`, the toolkit's source). A new source fails here until it is listed on purpose. In the settings mode, as
// in every mode, its commands are the window's and the settings' actions; the Workflows mode adds its own.
@(test)
the_palette_has_its_sources_in_every_mode :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	prefs_register(&app.prefs, context.temp_allocator)
	app.settings = prefs_read(&app.prefs)
	hw := &app.history_window
	defer {
		ui.palette_destroy(&hw.palette)
		settings_free(&app.settings)
		config.prefs_destroy(&app.prefs)
	}
	settings_enter(app)
	history_palette_feed(app)
	prefixes := ui.palette_prefixes(&hw.palette)
	testing.expectf(t, slice.equal(prefixes, []string{"> Commands", "@ Captures", "# Workflows", ": Settings"}), "the prefixes: %v", prefixes)
	table := hw.palette.commands.table
	testing.expect_value(t, len(table), len(History_Action) + len(Settings_Action))
	testing.expect_value(t, table[len(History_Action) + int(Settings_Action.Choose_Folder)].label, SETTINGS_ACTIONS[.Choose_Folder].label)
	// (a version, not a compare: what can act changed, the version moved; nothing changed, it stays)
	v := hw.palette_version
	history_palette_feed(app)
	testing.expect_value(t, hw.palette_version, v)
	// the Workflows mode: its commands after the others
	settings_leave(app)
	hw.workflow_mode.open = true
	history_palette_feed(app)
	testing.expect_value(t, len(hw.palette.commands.table), HISTORY_PALETTE_COUNT)
	hw.workflow_mode.open = false
}

// The workflows' add palette is the toolkit's chooser (ui.flow_palette): one source with no prefix, so no hint row; an
// item per kind of the catalog, its index the kind, its id the kind's name; given the same graph and version, it is not
// read again.
@(test)
the_add_palette_is_a_chooser :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.workflows = workflows_default()
	m := &app.history_window.workflow_mode
	defer {
		ui.palette_destroy(&m.add)
		workflows_free(&app.workflows)
	}
	wf := &app.workflows.set.list[0]
	ui.flow_palette(&m.add, &m.add_flow, &wf.graph, &CATALOG, nil, app.workflows.version)
	testing.expect_value(t, len(ui.palette_prefixes(&m.add)), 0)
	testing.expect_value(t, m.add_flow.source.prefix, ui.Palette_Prefix.None)
	v := m.add_flow.source.version
	ui.flow_palette(&m.add, &m.add_flow, &wf.graph, &CATALOG, nil, app.workflows.version)
	testing.expect_value(t, m.add_flow.source.version, v)
	items := ui.flow_palette_items(&wf.graph, &CATALOG, nil, context.temp_allocator)
	testing.expect_value(t, len(items), len(CATALOG.nodes))
	for it, k in items { testing.expect_value(t, it.id, CATALOG.nodes[k].name) }
}
