package cliche

// The views (gui_toolkit's views, src/md/features/views.md): cliche's dialogs and panes, which the user floats, opens in
// a window of their own or docks. One ui.Views for the program, given to every window's State (views_window): a view
// opens in the window whose build opens it. The toolkit keeps how the user shows each view, and which were open, in
// <state>/views.txt. The design: src/md/features/views.md.

import "core:strings"
import "gt:host"
import "gt:platform"
import "gt:ui"

// The ids of cliche's views. The confirmations are ui.confirm_open's.
PREVIEW_VIEW         :: "preview"
EDITOR_SIZE_VIEW     :: "editor_size"
HISTORY_DELETE_VIEW  :: "history_delete"
WORKFLOW_DELETE_VIEW :: "workflow_delete"
EDITOR_DROP_VIEW     :: "editor_drop"

// The start of every editor's instance name (Editor.name): the history's palette leaves the editors' views out.
EDITOR_INSTANCE :: "editor-"

// Where the views' memory is: the user's state folder, "views.txt".
views_path :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.State, APP_NAME, context.temp_allocator), "/views.txt"}, allocator)
}

// At the start, before any window opens: the memory read (`path` "": memory only), every view of cliche declared.
views_start :: proc(app: ^App, path: string) {
	ui.views_init(&app.views, {path = path})
	history_views_register(app)
	editor_views_register(app)
}

// A window opened: its State builds its views from the program's.
views_window :: proc(app: ^App, h: ^host.Host) {
	ui.set_views(&h.state, &app.views)
}

// At the top of the build of a window that owns views (the history, an editor). The backend of the views' windows is
// this window's host: the step after its frame opens and frames the windows of the views it owns (host.view_windows
// frames a view's window after its owner's frame, and the Views has one backend at a time).
views_owner_build :: proc(app: ^App, h: ^host.Host) {
	ui.views_set_windows(&app.views, host.view_windows(h))
}

// The moves of the views a window lists in its palette (float, dock, open in a window, re-attach, close), from `vc`,
// those `mine` keeps, in `allocator`. Their strings are vc's: the palette's table is made again when vc is.
views_moves :: proc(vc: ^ui.View_Commands, mine: proc(c: ui.View_Command, user: rawptr) -> bool, user: rawptr, allocator := context.allocator) -> (commands: []ui.Command, acts: []ui.View_Command) {
	out := make([dynamic]ui.Command, 0, len(vc.commands), allocator)
	out_acts := make([dynamic]ui.View_Command, 0, len(vc.acts), allocator)
	for c, i in vc.commands {
		if !mine(vc.acts[i], user) { continue }
		append(&out, c)
		append(&out_acts, vc.acts[i])
	}
	return out[:], out_acts[:]
}
