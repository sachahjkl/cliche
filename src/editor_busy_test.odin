package cliche

import "core:testing"

// A copy read back from the GPU takes a few frames: the bars must not turn disabled and back (they blinked at each Copy).
// A press meanwhile is refused by editor_action, not by the buttons' look.
@(test)
an_export_in_flight_leaves_the_actions_enabled :: proc(t: ^testing.T) {
	ed := new(Editor)
	defer free(ed)
	ed.has_picture = true
	for a in ([]Editor_Action{.Copy, .Save, .Pin, .Done, .Zoom_In}) {
		ed.exporting = false
		before := editor_action_enabled(ed, a)
		ed.exporting = true
		testing.expectf(t, editor_action_enabled(ed, a) == before, "%v changes while a copy is read back", a)
	}
	// (a tool chosen meanwhile is refused: the export draws the document as it is)
	tool := ed.model.tool
	editor_action(ed, .Tool_Rectangle)
	testing.expect_value(t, ed.model.tool, tool)
}
