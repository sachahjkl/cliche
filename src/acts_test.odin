package cliche

// The everything palette (gui_toolkit's src/md/features/everything-palette.md): a button that runs a command states its
// act name ("command:<id>"), where the palette's Shift+Enter on the command goes; a command that asks one value takes
// it from its form in the palette (Command.arguments).

import "core:testing"
import config "gt:config"
import "gt:font"
import "gt:ui"

// The settings' footer buttons run the settings' actions (and the history's Open the save folder): each states its act
// name. Built offscreen: no window, no desktop.
@(test)
a_command_s_button_states_its_act_name :: proc(t: ^testing.T) {
	// (on the heap: the state keeps them past each call)
	Fixture :: struct { fonts: font.State, theme: ui.Theme, s: ui.State }
	f := new(Fixture)
	defer free(f)
	font.init(&f.fonts)
	defer font.destroy(&f.fonts)
	base, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "fonts") { return }
	ui.apply_palette(&f.theme, ui.palette_of("Midnight"))
	defer ui.theme_destroy(&f.theme)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer ui.destroy(&f.s)
	app := new(App)
	defer free(app)

	for _ in 0 ..< 2 {
		ui.begin_build(&f.s, {
			window_size = {900, 600}, dt = 1.0 / 60, animations = false, dpi_scale = 1,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = base, font_size = 15, text_pad = 6},
		})
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###foot") {
			settings_page_foot(app, "save", 15)
			settings_page_foot(app, "upload", 15)
		}
		ui.end_build()
		free_all(context.temp_allocator)
	}
	for id in ([]string{"command:choose_folder", "command:open_folder", "command:import_uploader", "command:open_uploaders"}) {
		testing.expectf(t, ui.act_shown(id), "%s: its button states it", id)
	}
	testing.expect(t, !ui.act_shown("command:check_updates"), "a command with no button shown states nothing")
}

// Rename the workflow is a command with one argument, its new name: the palette's form gives it (the window's palette
// knows its argument while the Workflows mode shows), the workflow shown takes it trimmed; an empty name leaves it.
// Without a value (the list's button, a key) the name is typed in the list.
@(test)
rename_the_workflow_takes_its_name_from_the_palette :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	prefs_register(&app.prefs, context.temp_allocator)
	app.settings = prefs_read(&app.prefs)
	app.workflows = workflows_default()
	hw := &app.history_window
	m := &hw.workflow_mode
	defer {
		ui.palette_destroy(&hw.palette)
		ui.line_edit_destroy(&m.rename)
		workflows_free(&app.workflows)
		settings_free(&app.settings)
		config.prefs_destroy(&app.prefs)
	}
	args := WORKFLOW_ACTIONS[.Rename].arguments
	if !testing.expect_value(t, len(args), 1) { return }
	testing.expect_value(t, args[0].kind, config.Kind.String)

	// the window's palette, the Workflows mode shown: the command and its argument, for the forms runner
	m.open = true
	history_palette_feed(app)
	index, given := ui.palette_command_arguments(&hw.palette, WORKFLOW_ACTIONS[.Rename].id)
	testing.expect_value(t, index, len(History_Action) + len(Settings_Action) + int(Workflow_Action.Rename))
	testing.expect_value(t, len(given), 1)

	wf := &app.workflows.set.list[0]
	m.shown = wf.id
	v := app.workflows.version
	workflow_action(app, .Rename, []string{"  Harbour at dusk  "})
	testing.expect_value(t, wf.name, "Harbour at dusk")
	testing.expect(t, app.workflows.version > v, "a change of the workflows")
	workflow_action(app, .Rename, []string{"   "})
	testing.expect_value(t, wf.name, "Harbour at dusk")
	// no value: the list's field, on the workflow shown
	workflow_action(app, .Rename)
	testing.expect_value(t, m.renaming, wf.id)
	testing.expect_value(t, ui.line_edit_string(&m.rename), "Harbour at dusk")
}
