package cliche

import "core:slice"
import "core:testing"
import "gt:ui"

// A key that types text works only while no text field has the keyboard (gui_toolkit's src/md/features/commands.md):
// the editor's tools take single letters, as in every drawing program, and are a shape's text while it is typed. Each
// table lists the ones it means: a new key that types text fails here until it is listed on purpose.
@(test)
the_keys_that_type_text :: proc(t: ^testing.T) {
	editor := ui.command_typing_keys(slice.enumerated_array(&EDITOR_ACTIONS))
	testing.expectf(t, slice.equal(editor, []string{
		"Select and move: V", "Rectangle: R", "Ellipse: E", "Arrow: A", "Line: L", "Pen: P", "Text: T",
		"Speech balloon: Q", "Highlighter: H", "Pixelate: B", "Blur: G", "Smart eraser: X", "Magnifier: M",
		"Step number: N", "Crop: C", "Cut out a band: K", "Delete the selection: Backspace",
	}), "the editor's: %v", editor)
	history := ui.command_typing_keys(slice.enumerated_array(&HISTORY_ACTIONS))
	testing.expectf(t, slice.equal(history, []string{"Preview: Space"}), "the history's: %v", history)
	workflow := ui.command_typing_keys(slice.enumerated_array(&WORKFLOW_ACTIONS))
	testing.expectf(t, slice.equal(workflow, []string{"Add a step…: Shift+A", "Show the whole workflow: F"}), "the workflows': %v", workflow)
	settings := ui.command_typing_keys(slice.enumerated_array(&SETTINGS_ACTIONS))
	testing.expectf(t, len(settings) == 0, "the settings': %v", settings)
}

// Every command has an id (the person's keys and aliases, and the palette's memory, are stored by it). The main window's
// palette lists the history's, the settings' and the workflows' commands together: one table there.
@(test)
every_command_has_an_id :: proc(t: ^testing.T) {
	main_window := slice.concatenate([][]ui.Command{slice.enumerated_array(&HISTORY_ACTIONS), slice.enumerated_array(&SETTINGS_ACTIONS), slice.enumerated_array(&WORKFLOW_ACTIONS)}, context.temp_allocator)
	wrong := ui.command_ids_check(main_window, slice.enumerated_array(&EDITOR_ACTIONS))
	testing.expectf(t, len(wrong) == 0, "%v", wrong)
}

// One id in two tables is one command for the person's keys: the editor shares an id with the main window only for the
// same act. A new shared id fails here until it is listed on purpose.
@(test)
the_ids_the_editor_shares :: proc(t: ^testing.T) {
	shared := make([dynamic]string, context.temp_allocator)
	for e in EDITOR_ACTIONS {
		for h in HISTORY_ACTIONS { if h.id == e.id { append(&shared, e.id) } }
		for w in WORKFLOW_ACTIONS { if w.id == e.id { append(&shared, e.id) } }
		for s in SETTINGS_ACTIONS { if s.id == e.id { append(&shared, e.id) } }
	}
	testing.expectf(t, slice.equal(shared[:], []string{"undo", "redo", "select_all", "copy", "upload", "pin", "close", "shortcuts"}), "%v", shared)
}
