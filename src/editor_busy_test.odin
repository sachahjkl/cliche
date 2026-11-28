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

// Closing the editor right after Copy (while waiting for a filter or GPU readback) must not drop the copy or lose the
// close request: it defers the close until the shot is handed to the worker.
@(test)
closing_during_export_or_wait_defers_close_without_dropping_export :: proc(t: ^testing.T) {
	ed := new(Editor)
	defer free(ed)
	ed.has_picture = true

	// While waiting for a blur/mosaic filter before Copy: must NOT close immediately (which would drop export_wait).
	ed.export_wait = true
	ed.export_wait_for = .Copy
	editor_close_asked(ed)
	testing.expect(t, !ed.close_due, "close must wait for export_wait")
	testing.expect(t, ed.export_wait, "export_wait stays armed")
	testing.expect(t, ed.close_after_export, "close is deferred")

	// Transition into GPU readback (exporting): deferred close still waits.
	ed.export_wait = false
	ed.exporting = true
	editor_close_deferred(ed)
	testing.expect(t, !ed.close_due, "close must wait for GPU readback")
	testing.expect(t, ed.close_after_export, "close remains deferred")

	// Once GPU readback hands Job_Copy_Encode to the worker, the deferred close executes.
	ed.exporting = false
	editor_close_deferred(ed)
	testing.expect(t, !ed.close_after_export, "deferred flag cleared")
	testing.expect(t, ed.close_due, "editor closes now that Copy is on the worker")
}
