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
