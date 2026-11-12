package cliche

// Workflows: what happens after a capture, as a graph the user edits (workflow_view.odin). A workflow is nodes linked
// port to port; what flows on a link has a kind (a picture, a text, an address, a file). The start node, Capture, gives
// the picture taken; each capture's trigger (a shortcut, a command, the tray) runs exactly one workflow.
//
// This file is the model and its edits, pure: the catalog of node kinds is workflow_nodes.odin, a run of a graph
// workflow_run.odin, the file workflow_store.odin. The edits keep the graph valid (no cycle, one link into a port that
// takes one, one Capture node), so a run never meets a graph it cannot read.

import "core:strings"

// What flows on a link. Any: a port that takes every kind (Notify, Add to history).
Port_Kind :: enum u8 { Image, Text, Url, File, Any }

PORT_KIND_NAMES := [Port_Kind]string{.Image = "picture", .Text = "text", .Url = "address", .File = "file", .Any = "anything"}

// What starts a workflow: the captures of the shortcuts, the tray and the commands (cliche --region...). A trigger is a
// capture source and the workflow it runs; Edit, Qr and Ocr take a region.
Trigger :: enum u8 { Region, Screen, Window, Edit, Qr, Ocr }

Trigger_Set :: bit_set[Trigger; u8]

TRIGGER_NAMES := [Trigger]string{.Region = "region", .Screen = "screen", .Window = "window", .Edit = "edit", .Qr = "qr", .Ocr = "ocr"}

TRIGGER_TEXT := [Trigger]string{
	.Region = "Capture a region", .Screen = "Capture the screen", .Window = "Capture the window",
	.Edit = "Capture a region and edit", .Qr = "Read a QR code", .Ocr = "Read the text",
}

TRIGGER_SOURCE := [Trigger]Source{.Region = .Region, .Screen = .Screen, .Window = .Window, .Edit = .Region, .Qr = .Region, .Ocr = .Region}

// The parameters a node holds, by place in its kind's list (NODE_DEFS[kind].params). One value of each type: a number
// (Int, Float, Bool 0/1, Choice's index), a text (Text, Folder, Uploader; owned), a colour (straight RGBA).
NODE_PARAMS_MAX :: 8

Param :: struct {
	number: f64,
	text:   string,
	color:  [4]u8,
}

Workflow_Node :: struct {
	id:     u64,    // unique in its workflow, never reused (Workflow.next_id)
	kind:   Node_Kind,
	pos:    [2]f32,  // its top-left in the graph's units
	params: [NODE_PARAMS_MAX]Param,
}

// From an output port to an input port, each its place in its kind's list. The same layout as ui.Graph_Link.
Workflow_Link :: struct {
	from_node: u64,
	from_port: u32,
	to_node:   u64,
	to_port:   u32,
}

Workflow :: struct {
	id:       u64,          // unique in the list, never reused (Workflows.next_id)
	name:     string,       // owned
	triggers: Trigger_Set,
	nodes:    [dynamic]Workflow_Node,
	links:    [dynamic]Workflow_Link,
	next_id:  u64,
}

Workflows :: struct {
	list:    [dynamic]Workflow,
	next_id: u64,
	version: u64,   // raised at each change: what is made from the list (the view's graph, the file) is made again
}

////////////////////////////////
// Whole workflows

workflow_free :: proc(wf: ^Workflow) {
	delete(wf.name)
	for &n in wf.nodes { node_params_free(&n) }
	delete(wf.nodes)
	delete(wf.links)
	wf^ = {}
}

workflow_clone :: proc(wf: Workflow, allocator := context.allocator) -> Workflow {
	out := wf
	out.name = strings.clone(wf.name, allocator)
	out.nodes = make([dynamic]Workflow_Node, len(wf.nodes), allocator)
	for n, i in wf.nodes { out.nodes[i] = node_clone(n, allocator) }
	out.links = make([dynamic]Workflow_Link, len(wf.links), allocator)
	copy(out.links[:], wf.links[:])
	return out
}

workflows_free :: proc(ws: ^Workflows) {
	for &wf in ws.list { workflow_free(&wf) }
	delete(ws.list)
	ws^ = {}
}

node_clone :: proc(n: Workflow_Node, allocator := context.allocator) -> Workflow_Node {
	out := n
	for &p in out.params { if p.text != "" { p.text = strings.clone(p.text, allocator) } }
	return out
}

node_params_free :: proc(n: ^Workflow_Node) {
	for &p in n.params {
		delete(p.text)
		p.text = ""
	}
}

workflow_node :: proc(wf: ^Workflow, id: u64) -> ^Workflow_Node {
	for &n in wf.nodes { if n.id == id { return &n } }
	return nil
}

workflow_node_index :: proc(wf: ^Workflow, id: u64) -> int {
	for n, i in wf.nodes { if n.id == id { return i } }
	return -1
}

// The workflow `id` (nil: none, as after a delete).
workflows_find :: proc(ws: ^Workflows, id: u64) -> ^Workflow {
	for &wf in ws.list { if wf.id == id { return &wf } }
	return nil
}

// The workflow `t` runs (nil: none).
workflows_for :: proc(ws: ^Workflows, t: Trigger) -> ^Workflow {
	for &wf in ws.list { if t in wf.triggers { return &wf } }
	return nil
}

// `t` runs the workflow `id` now, and no other: each trigger runs exactly one workflow. `on` false: it runs none.
workflows_bind :: proc(ws: ^Workflows, id: u64, t: Trigger, on: bool) {
	for &wf in ws.list {
		if wf.id == id {
			if on { wf.triggers += {t} } else { wf.triggers -= {t} }
		} else if on {
			wf.triggers -= {t}
		}
	}
	ws.version += 1
}

// A new workflow at the end of the list, holding `wf` (taken). Returns its id.
workflows_add :: proc(ws: ^Workflows, wf: Workflow) -> u64 {
	wf := wf
	ws.next_id += 1
	wf.id = ws.next_id
	wf.triggers = {}   // (a new one takes no trigger from another: the user binds it)
	append(&ws.list, wf)
	ws.version += 1
	return wf.id
}

workflows_remove :: proc(ws: ^Workflows, id: u64) {
	for &wf, i in ws.list {
		if wf.id != id { continue }
		workflow_free(&wf)
		ordered_remove(&ws.list, i)
		ws.version += 1
		return
	}
}

// The triggers no workflow runs (the view says so).
workflows_unbound :: proc(ws: ^Workflows) -> Trigger_Set {
	bound: Trigger_Set
	for wf in ws.list { bound += wf.triggers }
	return ~bound
}

////////////////////////////////
// Edits of a graph

// A node of `kind` at `pos`, with its kind's default parameters. Returns its id; 0 when refused (a second Capture).
workflow_node_add :: proc(wf: ^Workflow, kind: Node_Kind, pos: [2]f32) -> u64 {
	if kind == .Capture {
		for n in wf.nodes { if n.kind == .Capture { return 0 } }
	}
	wf.next_id += 1
	n := Workflow_Node{id = wf.next_id, kind = kind, pos = pos}
	node_params_default(&n)
	append(&wf.nodes, n)
	return n.id
}

// The parameters of a node set to its kind's defaults.
node_params_default :: proc(n: ^Workflow_Node) {
	node_params_free(n)
	for d, i in NODE_DEFS[n.kind].params {
		n.params[i] = {number = d.default_number, color = d.default_color}
		if d.default_text != "" { n.params[i].text = strings.clone(d.default_text) }
	}
}

// Whether `l` may be made: both ends exist, the ports exist and their kinds agree, no cycle comes of it.
workflow_can_link :: proc(wf: ^Workflow, l: Workflow_Link) -> bool {
	from, to := workflow_node(wf, l.from_node), workflow_node(wf, l.to_node)
	if from == nil || to == nil || from == to { return false }
	outs, ins := NODE_DEFS[from.kind].outputs, NODE_DEFS[to.kind].inputs
	if int(l.from_port) >= len(outs) || int(l.to_port) >= len(ins) { return false }
	if !port_accepts(outs[l.from_port].kind, ins[l.to_port].kind) { return false }
	// (a link from a node that `to` reaches already would close a loop)
	return !workflow_reaches(wf, l.to_node, l.from_node)
}

// What an input of kind `to` takes: its own kind; a text takes an address or a file's path; Any takes all.
port_accepts :: proc(from, to: Port_Kind) -> bool {
	if to == .Any || from == to { return true }
	return to == .Text && (from == .Url || from == .File)
}

// Makes `l`. An input that takes one link loses the one it had (`replaced`). ok false: refused (workflow_can_link), or
// the link is there already.
workflow_link :: proc(wf: ^Workflow, l: Workflow_Link) -> (replaced: Maybe(Workflow_Link), ok: bool) {
	if !workflow_can_link(wf, l) { return nil, false }
	for have in wf.links { if have == l { return nil, false } }
	to := workflow_node(wf, l.to_node)
	if !NODE_DEFS[to.kind].inputs[l.to_port].multiple {
		for have, i in wf.links {
			if have.to_node == l.to_node && have.to_port == l.to_port {
				replaced = have
				ordered_remove(&wf.links, i)
				break
			}
		}
	}
	append(&wf.links, l)
	return replaced, true
}

workflow_unlink :: proc(wf: ^Workflow, l: Workflow_Link) -> bool {
	for have, i in wf.links {
		if have == l {
			ordered_remove(&wf.links, i)
			return true
		}
	}
	return false
}

// Deletes the nodes `ids` and every link that touches them. The Capture node stays: a workflow starts there.
workflow_nodes_delete :: proc(wf: ^Workflow, ids: []u64) -> (deleted: int) {
	for id in ids {
		i := workflow_node_index(wf, id)
		if i < 0 || wf.nodes[i].kind == .Capture { continue }
		node_params_free(&wf.nodes[i])
		ordered_remove(&wf.nodes, i)
		deleted += 1
		for j := len(wf.links) - 1; j >= 0; j -= 1 {
			if wf.links[j].from_node == id || wf.links[j].to_node == id { ordered_remove(&wf.links, j) }
		}
	}
	return
}

workflow_nodes_move :: proc(wf: ^Workflow, ids: []u64, delta: [2]f32) {
	for id in ids {
		if n := workflow_node(wf, id); n != nil { n.pos += delta }
	}
}

// Whether `to` is `from` or comes after it along the links.
workflow_reaches :: proc(wf: ^Workflow, from, to: u64) -> bool {
	if from == to { return true }
	seen := make(map[u64]bool, 16, context.temp_allocator)
	stack := make([dynamic]u64, 0, 16, context.temp_allocator)
	append(&stack, from)
	for len(stack) > 0 {
		id := pop(&stack)
		if id == to { return true }
		if seen[id] { continue }
		seen[id] = true
		for l in wf.links { if l.from_node == id { append(&stack, l.to_node) } }
	}
	return false
}

// Whether a node of `kind` is in the workflow (the editor is opened ahead when a capture's workflow has Annotate).
workflow_has :: proc(wf: ^Workflow, kind: Node_Kind) -> bool {
	for n in wf.nodes { if n.kind == kind { return true } }
	return false
}

////////////////////////////////
// The default workflows: what cliche did before workflows, so nothing is lost. Also what a missing or broken file
// gives.

workflows_default :: proc() -> (ws: Workflows) {
	{
		wf := Workflow{name = strings.clone("Screenshot")}
		capture := workflow_node_add(&wf, .Capture, {0, 70})
		copy_image := workflow_node_add(&wf, .Copy_Image, {230, 0})
		save := workflow_node_add(&wf, .Save_File, {230, 140})
		history := workflow_node_add(&wf, .Add_To_History, {460, 70})
		notify := workflow_node_add(&wf, .Notify, {460, 210})
		workflow_link(&wf, {capture, 0, copy_image, 0})
		workflow_link(&wf, {capture, 0, save, 0})
		workflow_link(&wf, {save, 0, history, 0})
		workflow_link(&wf, {save, 0, notify, 0})
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, .Region, true)
		workflows_bind(&ws, id, .Screen, true)
		workflows_bind(&ws, id, .Window, true)
	}
	{
		wf := Workflow{name = strings.clone("Edit then share")}
		capture := workflow_node_add(&wf, .Capture, {0, 70})
		annotate := workflow_node_add(&wf, .Annotate, {230, 70})
		copy_image := workflow_node_add(&wf, .Copy_Image, {460, 0})
		save := workflow_node_add(&wf, .Save_File, {460, 140})
		history := workflow_node_add(&wf, .Add_To_History, {690, 70})
		notify := workflow_node_add(&wf, .Notify, {690, 210})
		workflow_link(&wf, {capture, 0, annotate, 0})
		workflow_link(&wf, {annotate, 0, copy_image, 0})
		workflow_link(&wf, {annotate, 0, save, 0})
		workflow_link(&wf, {save, 0, history, 0})
		workflow_link(&wf, {save, 0, notify, 0})
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, .Edit, true)
	}
	reads := [2]struct { name: string, read: Node_Kind, trigger: Trigger }{
		{"Read a QR code", .Read_Qr, .Qr},
		{"Read the text", .Read_Text, .Ocr},
	}
	for r in reads {
		wf := Workflow{name = strings.clone(r.name)}
		capture := workflow_node_add(&wf, .Capture, {0, 70})
		read := workflow_node_add(&wf, r.read, {230, 70})
		copy_text := workflow_node_add(&wf, .Copy_Text, {460, 0})
		history := workflow_node_add(&wf, .Add_To_History, {460, 140})
		notify := workflow_node_add(&wf, .Notify, {690, 0})
		workflow_link(&wf, {capture, 0, read, 0})
		workflow_link(&wf, {read, 0, copy_text, 0})
		workflow_link(&wf, {read, 0, history, 0})
		workflow_link(&wf, {copy_text, 0, notify, 0})
		id := workflows_add(&ws, wf)
		workflows_bind(&ws, id, r.trigger, true)
	}
	return
}
