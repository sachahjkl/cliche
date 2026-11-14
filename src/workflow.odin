package cliche

// Workflows: what happens after a capture, as a graph the user edits (workflow_view.odin). A workflow is a gt:flowgraph
// graph against cliche's catalog (workflow_nodes.odin): nodes linked port to port, what flows on a link of a kind (a
// picture, a text, an address, a file, an action). The start node, Capture, gives the picture taken; each capture's
// trigger (a shortcut, a command, the tray) runs exactly one workflow.
//
// The list is a flowgraph.Graph_Set: each entry a workflow, its labels the names of the triggers that run it. The edits of
// a graph are flowgraph's (they keep it valid: no cycle, the kinds of a link agree, one Capture: its max_count and
// min_count); this file binds the triggers and gives the default workflows. A run is workflow_run.odin, the file
// workflow_store.odin.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import flowgraph "gt:flowgraph"
import i18n "gt:i18n"

// What starts a workflow: the captures of the shortcuts, the tray and the commands (cliche --region...). A trigger is a
// capture source and the workflow it runs; Edit, Qr and Ocr take a region. A workflow may also have a shortcut of its
// own, on its Capture node (Capture_Options): its keys capture that node's source and run that workflow. Two triggers
// capture nothing: Clipboard runs its workflow on what the clipboard holds, Upload_File on files chosen in the system's
// dialog (workflow_app.odin); their Capture node gives a picture, a file or a text.
Trigger :: enum u8 { Region, Screen, Window, Edit, Qr, Ocr, All_Screens, Last_Region, Clipboard, Upload_File }

Trigger_Set :: bit_set[Trigger; u16]

// A trigger's word: in the file (a workflow's labels), in `cliche --<word>`.
TRIGGER_NAMES := [Trigger]string{
	.Region = "region", .Screen = "screen", .Window = "window", .Edit = "edit", .Qr = "qr", .Ocr = "ocr",
	.All_Screens = "all-screens", .Last_Region = "last-region", .Clipboard = "upload-clipboard", .Upload_File = "upload-file",
}

// A trigger's word where a list of them is shown (the Capture node, the workflows' list): TRIGGER_NAMES' words, in the
// language in use (i18n.tr where shown).
TRIGGER_WORDS := [Trigger]string{
	.Region = i18n.later("region"), .Screen = i18n.later("screen"), .Window = i18n.later("window"), .Edit = i18n.later("edit"), .Qr = i18n.later("qr"), .Ocr = i18n.later("ocr"),
	.All_Screens = i18n.later("all screens"), .Last_Region = i18n.later("last region"), .Clipboard = i18n.later("clipboard"), .Upload_File = i18n.later("files"),
}

TRIGGER_TEXT := [Trigger]string{
	.Region = i18n.later("Capture a region"), .Screen = i18n.later("Capture the screen"), .Window = i18n.later("Capture the window"),
	.Edit = i18n.later("Capture a region and edit"), .Qr = i18n.later("Read a QR code"), .Ocr = i18n.later("Read the text"),
	.All_Screens = i18n.later("Capture all the screens"), .Last_Region = i18n.later("Capture the last region again"),
	.Clipboard = i18n.later("Upload the clipboard"), .Upload_File = i18n.later("Upload files"),
}

// (Clipboard and Upload_File capture nothing: their source is never read)
TRIGGER_SOURCE := [Trigger]Source{
	.Region = .Region, .Screen = .Screen, .Window = .Window, .Edit = .Region, .Qr = .Region, .Ocr = .Region,
	.All_Screens = .All_Screens, .Last_Region = .Last_Region, .Clipboard = .Region, .Upload_File = .Region,
}

// What a source captures, as the Capture node's choices say it (the same words: one translation).
CAPTURE_SOURCE_TEXT := [Source]string{
	.Region = i18n.later("A region"), .Screen = i18n.later("The screen"), .Window = i18n.later("The window in front"),
	.All_Screens = i18n.later("All the screens"), .Last_Region = i18n.later("The last region"), .Color = i18n.later("A colour"),
}

// What a capture runs: the workflow of a trigger, or (`workflow` not 0) a workflow named by its own shortcut.
Capture_Target :: struct {
	trigger:  Trigger,
	workflow: u64,
}

// What a workflow's Capture node says of its captures (its parameters, workflow_nodes.odin): the source and the keys
// of its own shortcut, and for every capture that runs it, a delay and the pointer.
Capture_Options :: struct {
	source:   Source,   // what its own shortcut captures (one of the first five)
	shortcut: string,   // its own keys, as platform.hotkey_text words them ("": none); the node's
	delay_s:  int,      // seconds before the picture is taken (a countdown is shown)
	cursor:   bool,     // the pointer in the picture, where the system draws it (capture.cursor_support)
}

// The Capture node's options of `wf` (zero: no workflow, or no Capture node).
capture_options :: proc(wf: ^flowgraph.Graph_Entry) -> (o: Capture_Options) {
	if wf == nil { return }
	for &n in wf.graph.nodes {
		if Node_Kind(n.kind) != .Capture { continue }
		o.source = Source(clamp(flowgraph.param_int(&CATALOG, &n, "source"), 0, int(Source.Last_Region)))
		o.shortcut = flowgraph.param_text(&CATALOG, &n, "shortcut")
		o.delay_s = max(flowgraph.param_int(&CATALOG, &n, "delay"), 0)
		o.cursor = flowgraph.param_bool(&CATALOG, &n, "cursor")
		return
	}
	return
}

// The workflow a capture runs (nil: none).
workflows_target :: proc(ws: ^Workflows, target: Capture_Target) -> ^flowgraph.Graph_Entry {
	if target.workflow != 0 { return workflows_find(ws, target.workflow) }
	return workflows_for(ws, target.trigger)
}

// The id a workflow's own shortcut has in the shortcuts' service (and with the system, which keeps the user's keys
// under it): stable while the workflow is there.
WORKFLOW_SHORTCUT_PREFIX :: "workflow-"

workflow_shortcut_id :: proc(id: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s%d", WORKFLOW_SHORTCUT_PREFIX, id, allocator = allocator)
}

// The workflow of a shortcut's id; false: the id is not a workflow's.
workflow_of_shortcut :: proc(shortcut_id: string) -> (id: u64, ok: bool) {
	if !strings.has_prefix(shortcut_id, WORKFLOW_SHORTCUT_PREFIX) { return }
	v, parsed := strconv.parse_u64_of_base(shortcut_id[len(WORKFLOW_SHORTCUT_PREFIX):], 10)
	return v, parsed && v != 0
}

// A workflow with keys of its own, as the shortcuts' service is given it.
Workflow_Shortcut :: struct {
	workflow: u64,
	name:     string,   // the workflow's (not owned)
	keys:     string,   // as platform.hotkey_text words them (not owned)
	source:   Source,
}

// The workflows that have keys of their own, in the list's order (temp allocator).
workflows_shortcuts :: proc(ws: ^Workflows) -> []Workflow_Shortcut {
	out := make([dynamic]Workflow_Shortcut, 0, len(ws.set.list), context.temp_allocator)
	for &wf in ws.set.list {
		o := capture_options(&wf)
		if strings.trim_space(o.shortcut) == "" { continue }
		append(&out, Workflow_Shortcut{wf.id, wf.name, o.shortcut, o.source})
	}
	return out[:]
}

Workflows :: struct {
	set:     flowgraph.Graph_Set,
	version: u64,   // raised at each change: what is made from the list (the view's graph, the file) is made again
}

workflows_free :: proc(ws: ^Workflows) {
	flowgraph.set_destroy(&ws.set)
	ws^ = {}
}

// The workflow `id` (nil: none, as after a delete).
workflows_find :: proc(ws: ^Workflows, id: u64) -> ^flowgraph.Graph_Entry {
	return flowgraph.set_find(&ws.set, id)
}

// The triggers that run `wf`: its labels that name one.
workflow_triggers :: proc(wf: ^flowgraph.Graph_Entry) -> (set: Trigger_Set) {
	for l in wf.labels {
		for name, t in TRIGGER_NAMES { if name == l { set += {t} } }
	}
	return
}

// The workflow `t` runs (nil: none).
workflows_for :: proc(ws: ^Workflows, t: Trigger) -> ^flowgraph.Graph_Entry {
	for &wf in ws.set.list { if slice.contains(wf.labels[:], TRIGGER_NAMES[t]) { return &wf } }
	return nil
}

// `t` runs the workflow `id` now, and no other: each trigger runs exactly one workflow. `on` false: it runs none.
workflows_bind :: proc(ws: ^Workflows, id: u64, t: Trigger, on: bool) {
	for &wf in ws.set.list {
		if wf.id == id {
			label_set(&wf, TRIGGER_NAMES[t], on)
		} else if on {
			label_set(&wf, TRIGGER_NAMES[t], false)
		}
	}
	ws.version += 1
}

// A new workflow at the end of the list, holding `wf` (taken). Returns its id.
workflows_add :: proc(ws: ^Workflows, wf: flowgraph.Graph_Entry) -> u64 {
	wf := wf
	// (a new one takes no trigger from another: the user binds it)
	for l in wf.labels { delete(l) }
	clear(&wf.labels)
	id := flowgraph.set_add(&ws.set, wf)
	ws.version += 1
	return id
}

workflows_remove :: proc(ws: ^Workflows, id: u64) {
	if flowgraph.set_remove(&ws.set, id) { ws.version += 1 }
}

// The triggers no workflow runs (the view says so).
workflows_unbound :: proc(ws: ^Workflows) -> Trigger_Set {
	bound: Trigger_Set
	for &wf in ws.set.list { bound += workflow_triggers(&wf) }
	return ~bound
}

// The labels the file gave, made the triggers' rule: a word that names no trigger goes, and a trigger runs the first
// workflow that names it (a hand-edited file may name one twice).
workflows_triggers_fix :: proc(ws: ^Workflows) {
	bound: Trigger_Set
	for &wf in ws.set.list {
		for i := 0; i < len(wf.labels); {
			t, known := trigger_named(wf.labels[i])
			if known && t not_in bound {
				bound += {t}
				i += 1
				continue
			}
			delete(wf.labels[i])
			ordered_remove(&wf.labels, i)
		}
	}
}

trigger_named :: proc(name: string) -> (Trigger, bool) {
	for n, t in TRIGGER_NAMES { if n == name { return t, true } }
	return {}, false
}

// Whether `wf` holds a node of `kind` (the editor is opened ahead when a capture's workflow has Annotate).
workflow_has :: proc(wf: ^flowgraph.Graph_Entry, kind: Node_Kind) -> bool {
	return flowgraph.graph_count(&wf.graph, int(kind)) > 0
}

// The label `name` of `wf` there or not.
@(private = "file")
label_set :: proc(wf: ^flowgraph.Graph_Entry, name: string, on: bool) {
	for l, i in wf.labels {
		if l != name { continue }
		if !on {
			delete(l)
			ordered_remove(&wf.labels, i)
		}
		return
	}
	if on { append(&wf.labels, strings.clone(name)) }
}

////////////////////////////////
// The default workflows: what cliche did before workflows, so nothing is lost. Also what a missing or broken file
// gives.

// The keys of "Edit then share" (a region, then the editor) in the default workflows.
EDIT_SHORTCUT_DEFAULT :: "Ctrl+Alt+E"

workflows_default :: proc() -> (ws: Workflows) {
	add :: proc(g: ^flowgraph.Graph, kind: Node_Kind, pos: [2]f32) -> u64 {
		return flowgraph.node_add(g, &CATALOG, int(kind), pos)
	}
	// (each default link is from the first output to the first input)
	link :: proc(g: ^flowgraph.Graph, from, to: u64) {
		_, _ = flowgraph.link(g, &CATALOG, {from, 0, to, 0})
	}

	{
		wf := flowgraph.Graph_Entry{name = strings.clone(i18n.tr("Screenshot"))}
		g := &wf.graph
		capture := add(g, .Capture, {0, 70})
		copy_image := add(g, .Copy_Image, {230, 0})
		save := add(g, .Save_File, {230, 140})
		history := add(g, .Add_To_History, {460, 70})
		notify := add(g, .Notify, {460, 210})
		link(g, capture, copy_image)
		link(g, capture, save)
		link(g, save, history)
		link(g, save, notify)
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, .Region, true)
		workflows_bind(&ws, id, .Screen, true)
		workflows_bind(&ws, id, .Window, true)
		workflows_bind(&ws, id, .All_Screens, true)
		workflows_bind(&ws, id, .Last_Region, true)
	}
	{
		wf := flowgraph.Graph_Entry{name = strings.clone(i18n.tr("Edit then share"))}
		g := &wf.graph
		capture := add(g, .Capture, {0, 70})
		// (its own keys: "Capture a region and edit" has a shortcut from the start)
		if n := flowgraph.graph_node(g, capture); n != nil {
			if keys := flowgraph.param(&CATALOG, n, "shortcut"); keys != nil {
				delete(keys.text)
				keys.text = strings.clone(EDIT_SHORTCUT_DEFAULT)
			}
		}
		annotate := add(g, .Annotate, {230, 70})
		copy_image := add(g, .Copy_Image, {460, 0})
		save := add(g, .Save_File, {460, 140})
		history := add(g, .Add_To_History, {690, 70})
		notify := add(g, .Notify, {690, 210})
		link(g, capture, annotate)
		link(g, annotate, copy_image)
		link(g, annotate, save)
		link(g, save, history)
		link(g, save, notify)
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, .Edit, true)
	}
	reads := [2]struct { name: string, read: Node_Kind, trigger: Trigger }{
		{i18n.later("Read a QR code"), .Read_Qr, .Qr},
		{i18n.later("Read the text"), .Read_Text, .Ocr},
	}
	for r in reads {
		wf := flowgraph.Graph_Entry{name = strings.clone(i18n.tr(r.name))}
		g := &wf.graph
		capture := add(g, .Capture, {0, 70})
		read := add(g, r.read, {230, 70})
		copy_text := add(g, .Copy_Text, {460, 0})
		history := add(g, .Add_To_History, {460, 140})
		notify := add(g, .Notify, {690, 0})
		link(g, capture, read)
		link(g, read, copy_text)
		link(g, read, history)
		link(g, copy_text, notify)
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, r.trigger, true)
	}
	{
		// (the clipboard's and the files' runs: whichever of the Capture node's outputs a run gives is uploaded)
		wf := flowgraph.Graph_Entry{name = strings.clone(i18n.tr("Upload"))}
		g := &wf.graph
		capture := add(g, .Capture, {0, 70})
		upload := add(g, .Upload, {230, 70})
		copy_text := add(g, .Copy_Text, {460, 0})
		history := add(g, .Add_To_History, {460, 140})
		notify := add(g, .Notify, {690, 0})
		for port in ([]u32{CAPTURE_PORT_PICTURE, CAPTURE_PORT_FILE, CAPTURE_PORT_TEXT}) {
			_, _ = flowgraph.link(g, &CATALOG, {capture, port, upload, 0})
		}
		link(g, upload, copy_text)
		link(g, upload, history)
		link(g, copy_text, notify)
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, .Clipboard, true)
		workflows_bind(&ws, id, .Upload_File, true)
	}
	return
}
