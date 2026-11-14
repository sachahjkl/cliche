package cliche

// The views (gui_toolkit's views, src/md/features/views.md): cliche's dialogs and panes, which the user floats, opens in
// a window of their own or docks. One ui.Views for the program, given to every window's State (views_window): a view
// opens in the window whose build opens it. The toolkit keeps how the user shows each view, and which were open, in
// <state>/views.txt. The design: src/md/features/views.md.

import host "gt:host"
import "gt:platform"
import "gt:ui"

// The ids of cliche's views. The confirmations are ui.confirm_open's.
PREVIEW_VIEW         :: "preview"
EDITOR_SIZE_VIEW     :: "editor_size"
HISTORY_DELETE_VIEW  :: "history_delete"
WORKFLOW_DELETE_VIEW :: "workflow_delete"
EDITOR_DROP_VIEW     :: "editor_drop"

// The start of every editor's instance name (Editor.name): each editor's views are instances of their own.
EDITOR_INSTANCE :: "editor-"

// Where the views' memory is: the user's state folder, "views.txt".
views_path :: proc(allocator := context.temp_allocator) -> string {
	return path_join(platform.user_dir(.State, APP_NAME, context.temp_allocator), "views.txt", allocator)
}

// At the start, before any window opens: the memory read (`path` "": memory only), the backend of the views' windows
// (one for every owner window: each view's window is framed after the window that owns the view), every view of
// cliche declared.
views_start :: proc(app: ^App, path: string) {
	ui.views_init(&app.views, {path = path})
	ui.views_set_windows(&app.views, host.view_windows(&app.shared))
	history_views_register(app)
	editor_views_register(app)
}

// A window opened: its State builds its views from the program's.
views_window :: proc(app: ^App, h: ^host.Host) {
	ui.set_views(&h.state, &app.views)
}

// The moves of the views a window lists in its palette (float, dock, open in a window, re-attach, close): `vc` holds
// those of the views that window owns (views_commands_update with its State). The palettes' own are left out: a
// palette is open while it lists them. In `allocator`; their strings are vc's: the palette's table is made again when
// vc is.
views_moves :: proc(vc: ^ui.View_Commands, allocator := context.allocator) -> (commands: []ui.Command, acts: []ui.View_Command) {
	out := make([dynamic]ui.Command, 0, len(vc.commands), allocator)
	out_acts := make([dynamic]ui.View_Command, 0, len(vc.acts), allocator)
	for c, i in vc.commands {
		if vc.acts[i].id == ui.PALETTE_VIEW { continue }
		append(&out, c)
		append(&out_acts, vc.acts[i])
	}
	return out[:], out_acts[:]
}
