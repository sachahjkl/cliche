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

import "core:slice"
import "core:strings"
import flowgraph "gt:flowgraph"

// What starts a workflow: the captures of the shortcuts, the tray and the commands (cliche --region...). A trigger is a
// capture source and the workflow it runs; Edit, Qr and Ocr take a region.
Trigger :: enum u8 { Region, Screen, Window, Edit, Qr, Ocr }

Trigger_Set :: bit_set[Trigger; u8]

// A trigger's word: in the file (a workflow's labels), on the Capture node, in `cliche --<word>`.
TRIGGER_NAMES := [Trigger]string{.Region = "region", .Screen = "screen", .Window = "window", .Edit = "edit", .Qr = "qr", .Ocr = "ocr"}

TRIGGER_TEXT := [Trigger]string{
	.Region = "Capture a region", .Screen = "Capture the screen", .Window = "Capture the window",
	.Edit = "Capture a region and edit", .Qr = "Read a QR code", .Ocr = "Read the text",
}

TRIGGER_SOURCE := [Trigger]Source{.Region = .Region, .Screen = .Screen, .Window = .Window, .Edit = .Region, .Qr = .Region, .Ocr = .Region}

Workflows :: struct {
	set:     flowgraph.Graph_Set,
	version: u64,   // raised at each change: what is made from the list (the view's graph, the file) is made again
}

workflows_free :: proc(ws: ^Workflows) {
	flowgraph.set_free(&ws.set)
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

workflows_default :: proc() -> (ws: Workflows) {
	add :: proc(g: ^flowgraph.Graph, kind: Node_Kind, pos: [2]f32) -> u64 {
		return flowgraph.node_add(g, &CATALOG, int(kind), pos)
	}
	// (each default link is from the first output to the first input)
	link :: proc(g: ^flowgraph.Graph, from, to: u64) {
		_, _ = flowgraph.link(g, &CATALOG, {from, 0, to, 0})
	}

	{
		wf := flowgraph.Graph_Entry{name = strings.clone("Screenshot")}
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
	}
	{
		wf := flowgraph.Graph_Entry{name = strings.clone("Edit then share")}
		g := &wf.graph
		capture := add(g, .Capture, {0, 70})
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
		{"Read a QR code", .Read_Qr, .Qr},
		{"Read the text", .Read_Text, .Ocr},
	}
	for r in reads {
		wf := flowgraph.Graph_Entry{name = strings.clone(r.name)}
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
	return
}
