package cliche

// The workflows' file: <config dir>/cliche/workflows.json, the text of a flowgraph.Graph_Set (flowgraph.set_text and
// set_parse) under cliche's own keys: the list is "workflows", each one's labels its "triggers". The worker reads it at
// the start (Job_Workflows_Load); after each change the interface's thread makes its text and the worker writes it
// (Job_Write), at the end of a gesture, not at each frame (workflow_app.odin). A missing file gives the default
// workflows; a file that cannot be read gives them too, is kept aside as workflows.json.broken, and the Workflows mode
// says why.
//
//   {"version": 1, "workflows": [{"id": 1, "name": "Screenshot", "triggers": ["region"], "next_id": 5,
//     "nodes": [{"id": 1, "kind": "resize", "x": 0, "y": 120, "params": {"percent": 50, "color": "#000000ff"}}],
//     "links": [{"from": 1, "from_port": 0, "to": 2, "to_port": 0}]}]}
//
// What the file lacks takes its default; what it has that cliche does not know is dropped (a node of an unknown kind, a
// link that is not valid, a trigger's word that names none, a trigger a workflow before it took).

import "core:fmt"
import "core:os"
import "core:strings"
import flowgraph "gt:flowgraph"
import "gt:platform"
import i18n "gt:i18n"

WORKFLOWS_FORMAT :: flowgraph.Store_Format{version = 1, list = "workflows", labels = "triggers"}

workflows_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/workflows.json"}, allocator)
}

// The workflows of the file, or the defaults (on the worker: it reads the disk). problem: why the file was not used
// (owned; "" none).
workflows_load :: proc() -> (ws: Workflows, problem: string) {
	return workflows_load_from(workflows_file())
}

// The same, from the file at `path` (a test's file).
workflows_load_from :: proc(path: string) -> (ws: Workflows, problem: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		if os.exists(path) { return workflows_default(), fmt.aprintf(i18n.tr("%s cannot be read: the default workflows are in its place."), path) }
		return workflows_default(), ""
	}
	list, why := workflows_parse(string(data))
	if why == "" { return list, "" }
	workflows_free(&list)
	aside := strings.concatenate({path, ".broken"}, context.temp_allocator)
	_ = os.rename(path, aside)
	return workflows_default(), fmt.aprintf(i18n.tr("%s cannot be read (%s): it is kept as %s, and the default workflows are in its place."), path, why, aside)
}

// The file's text (owned).
workflows_text :: proc(ws: ^Workflows) -> string {
	return flowgraph.set_text(&ws.set, &CATALOG, WORKFLOWS_FORMAT)
}

// The workflows of `text`. why: "" when it reads; else what is wrong (temp allocator), and `ws` holds what was read so
// far (to free).
workflows_parse :: proc(text: string) -> (ws: Workflows, why: string) {
	ws.set, why = flowgraph.set_parse(text, &CATALOG, WORKFLOWS_FORMAT)
	if why != "" { return }
	workflows_triggers_fix(&ws)
	ws.version += 1
	return
}
