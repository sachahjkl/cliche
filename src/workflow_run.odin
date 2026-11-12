package cliche

// A run of a workflow: pure, on the interface's thread, tested without a window (workflow_run_test.odin). The app
// (workflow_app.odin) gives it a picture, takes the tasks that are ready (run_next), does each one where it must be done
// (a job of the worker, the clipboard here, the editor) and gives back what each gave (run_finish). The run ends when
// no node can run any more (run_over); run_summary then says what it did, for one notification.
//
// Each node of a run is a small state machine (node_step):
//
//   Idle -> Running (worker, interface) | Waiting (the editor: a person) -> Done | Failed
//   Idle -> Done (the run decides it itself: Capture, Condition, Annotate passed through)
//   Idle -> Skipped (an input will never come; an effect in a preview); Waiting -> Skipped (the editor closed without Done)
//
// A node becomes ready when each of its inputs is decided: every node before it is Done, Failed or Skipped. It runs when
// each input that takes one link has its value, and an input that takes several has at least one; else it is Skipped,
// and so is what follows it. A Condition gives its picture on one output only: the other branch is Skipped.
//
// Pictures are shared, read only: fan-out gives each branch the same picture, and a node that changes it makes a new one
// (workflow_ops.odin). A picture is let go when every node that reads it is decided and no job holds it.

import "core:strings"

Node_State :: enum u8 { Idle, Waiting, Running, Done, Failed, Skipped }

NODE_STATE_DECIDED :: bit_set[Node_State]{.Done, .Failed, .Skipped}

// What happens to a node of a run.
Node_Event :: enum u8 {
	Start,      // its work goes to the worker or is done on the interface's thread
	Wait,       // its work waits for a person (the editor)
	Pass,       // the run decided it at once (Capture, Condition, Annotate passed through)
	Skip,       // it will not run
	Finished,   // its work is done
	Failed,     // its work failed
	Cancelled,  // the person gave up (the editor closed without Done)
}

// The state after `e` in `s`. ok false: `e` means nothing in `s` (a late result), and `s` stays.
node_step :: proc(s: Node_State, e: Node_Event) -> (next: Node_State, ok: bool) {
	#partial switch s {
	case .Idle:
		#partial switch e {
		case .Start: return .Running, true
		case .Wait:  return .Waiting, true
		case .Pass:  return .Done, true
		case .Skip:  return .Skipped, true
		}
	case .Running:
		#partial switch e {
		case .Finished: return .Done, true
		case .Failed:   return .Failed, true
		}
	case .Waiting:
		#partial switch e {
		case .Finished:  return .Done, true
		case .Failed:    return .Failed, true
		case .Cancelled: return .Skipped, true
		}
	}
	return s, false
}

// A picture shared by the nodes that read it. Read only once made: `refs` counts the run's outputs and the jobs that
// hold it (on the interface's thread only); the last one frees it.
Run_Picture :: struct {
	shot: Shot,
	refs: int,
}

picture_make :: proc(shot: Shot) -> ^Run_Picture {
	p := new(Run_Picture)
	p^ = {shot = shot, refs = 1}
	return p
}

picture_hold :: proc(p: ^Run_Picture) -> ^Run_Picture {
	if p != nil { p.refs += 1 }
	return p
}

picture_release :: proc(p: ^Run_Picture) {
	if p == nil { return }
	p.refs -= 1
	if p.refs > 0 { return }
	shot_free(&p.shot)
	free(p)
}

// What flows on a link.
Run_Value :: struct {
	kind:    Port_Kind,
	picture: ^Run_Picture,   // Image: one reference of its own
	text:    string,         // Text, Url (the address), File (the path); owned
	origin:  Node_Kind,      // the node that made it (the history's kind of a text: a QR code's, a text read)
	size:    [2]int,         // File: the picture's, in pixels
	bytes:   i64,            // File: the file's
}

value_free :: proc(v: ^Run_Value) {
	picture_release(v.picture)
	delete(v.text)
	v^ = {}
}

// A copy that the caller owns (a reference of its own on the picture).
value_clone :: proc(v: Run_Value) -> Run_Value {
	out := v
	out.picture = picture_hold(v.picture)
	out.text = strings.clone(v.text)
	return out
}

OUTPUTS_MAX :: 2

Run_Node :: struct {
	state:   Node_State,
	outputs: [OUTPUTS_MAX]Run_Value,
	made:    bit_set[0 ..< OUTPUTS_MAX],   // the outputs it gave (a Condition gives one)
	message: string,                       // why it failed or was skipped (owned)
}

Run :: struct {
	id:        u64,
	workflow:  Workflow,   // a copy (owned): the user may change the workflow while it runs
	source:    Source,
	preview:   bool,       // the effects are off (the clipboard, files, uploads, notifications, the history)
	annotated: bool,       // the picture comes from the editor already: Annotate passes it on
	nodes:     []Run_Node, // in the order of workflow.nodes
}

Run_Start :: struct {
	id:        u64,
	source:    Source,
	preview:   bool,
	annotated: bool,
}

// A node ready to run where its kind says (NODE_DEFS[kind].place). `inputs`: its values, each port's in link order;
// the run's, valid until the node is finished (the caller clones what a job takes).
Run_Task :: struct {
	node:   int,
	id:     u64,
	kind:   Node_Kind,
	inputs: []Run_Value,
}

// What a node gave (taken by run_finish).
Run_Result :: struct {
	ok:      bool,
	message: string,                   // why it failed (not kept: a copy is)
	outputs: [OUTPUTS_MAX]Run_Value,
	made:    bit_set[0 ..< OUTPUTS_MAX],
}

// Starts a run of `wf` (copied) on `shot` (taken): the Capture node gives it. A workflow with no Capture node has nothing
// to run: every node is Skipped.
run_start :: proc(run: ^Run, wf: Workflow, shot: Shot, start: Run_Start) {
	run^ = {id = start.id, source = start.source, preview = start.preview, annotated = start.annotated}
	run.workflow = workflow_clone(wf)
	run.nodes = make([]Run_Node, len(run.workflow.nodes))
	picture := picture_make(shot)
	given := false
	for n, i in run.workflow.nodes {
		if n.kind != .Capture || given { continue }
		rn := &run.nodes[i]
		rn.state, _ = node_step(rn.state, .Pass)
		rn.outputs[0] = {kind = .Image, picture = picture, origin = .Capture}
		rn.made = {0}
		given = true
	}
	if !given { picture_release(picture) }
}

run_free :: proc(run: ^Run) {
	for &rn in run.nodes {
		for &v in rn.outputs { value_free(&v) }
		delete(rn.message)
	}
	delete(run.nodes)
	workflow_free(&run.workflow)
	run^ = {}
}

// The nodes that became ready, now Running or Waiting: the caller does each one and calls run_finish. What the run
// decides itself (a Condition, a skip) is done here, until nothing more changes. Temp allocator.
run_next :: proc(run: ^Run) -> []Run_Task {
	tasks := make([dynamic]Run_Task, 0, 4, context.temp_allocator)
	for changed := true; changed; {
		changed = false
		for &rn, i in run.nodes {
			if rn.state != .Idle { continue }
			n := &run.workflow.nodes[i]
			inputs, readiness := run_inputs(run, i)
			switch readiness {
			case .Pending:
				continue
			case .Missing:
				run_set(run, i, .Skip, "nothing comes in")
				changed = true
				continue
			case .Ready:
			}
			def := NODE_DEFS[n.kind]
			changed = true
			switch {
			case run.preview && def.effect:
				run_set(run, i, .Skip, "off in a preview")
			case n.kind == .Annotate && (run.preview || run.annotated):
				// (the editor is not opened for a preview; a picture from the editor is annotated already)
				run_pass(run, i, 0, inputs[0])
			case n.kind == .Condition:
				run_pass(run, i, condition_holds(n, inputs[0], run.source) ? 0 : 1, inputs[0])
			case def.place == .Editor:
				run_set(run, i, .Wait, "")
				append(&tasks, Run_Task{node = i, id = n.id, kind = n.kind, inputs = inputs})
			case:
				run_set(run, i, .Start, "")
				append(&tasks, Run_Task{node = i, id = n.id, kind = n.kind, inputs = inputs})
			}
		}
	}
	return tasks[:]
}

// What node `node` gave. False: it was not running (a late result: `r` is freed).
run_finish :: proc(run: ^Run, node: int, r: Run_Result) -> bool {
	r := r
	if node < 0 || node >= len(run.nodes) || (run.nodes[node].state != .Running && run.nodes[node].state != .Waiting) {
		for &v in r.outputs { value_free(&v) }
		return false
	}
	rn := &run.nodes[node]
	if !r.ok {
		for &v in r.outputs { value_free(&v) }
		run_set(run, node, .Failed, r.message)
	} else {
		rn.outputs, rn.made = r.outputs, r.made
		run_set(run, node, .Finished, "")
	}
	run_let_go(run)
	return true
}

// The person gave up on node `node` (the editor closed without Done): it and what follows it are Skipped.
run_cancel :: proc(run: ^Run, node: int, message: string) -> bool {
	if node < 0 || node >= len(run.nodes) || run.nodes[node].state != .Waiting { return false }
	run_set(run, node, .Cancelled, message)
	run_let_go(run)
	return true
}

// Every node is decided: nothing runs, nothing waits, nothing can start.
run_over :: proc(run: ^Run) -> bool {
	for rn in run.nodes { if rn.state not_in NODE_STATE_DECIDED { return false } }
	return true
}

// Whether a node waits for a person or the worker.
run_busy :: proc(run: ^Run) -> bool {
	for rn in run.nodes { if rn.state == .Running || rn.state == .Waiting { return true } }
	return false
}

////////////////////////////////
// Inside a run

@(private = "file")
Readiness :: enum u8 { Pending, Ready, Missing }

// The values that come into node `i`, and whether it can run: Pending while a node before it is not decided; Missing
// when an input that needs a value has none.
@(private = "file")
run_inputs :: proc(run: ^Run, i: int) -> (values: []Run_Value, readiness: Readiness) {
	n := &run.workflow.nodes[i]
	out := make([dynamic]Run_Value, 0, 2, context.temp_allocator)
	for _, p in NODE_DEFS[n.kind].inputs {
		got := 0
		for l in run.workflow.links {
			if l.to_node != n.id || l.to_port != u32(p) { continue }
			from := workflow_node_index(&run.workflow, l.from_node)
			if from < 0 { continue }
			src := &run.nodes[from]
			if src.state not_in NODE_STATE_DECIDED { return nil, .Pending }
			if src.state == .Done && int(l.from_port) < OUTPUTS_MAX && int(l.from_port) in src.made {
				append(&out, src.outputs[l.from_port])
				got += 1
			}
		}
		if got == 0 { return nil, .Missing }
	}
	return out[:], .Ready
}

@(private = "file")
run_set :: proc(run: ^Run, i: int, e: Node_Event, message: string) {
	rn := &run.nodes[i]
	next, ok := node_step(rn.state, e)
	if !ok { return }
	rn.state = next
	if message != "" {
		delete(rn.message)
		rn.message = strings.clone(message)
	}
}

// Node `i` gives `v` (a reference of its own) on output `port` at once.
@(private = "file")
run_pass :: proc(run: ^Run, i: int, port: int, v: Run_Value) {
	rn := &run.nodes[i]
	rn.outputs[port] = value_clone(v)
	rn.outputs[port].origin = run.workflow.nodes[i].kind == .Condition ? v.origin : run.workflow.nodes[i].kind
	rn.made = {port}
	run_set(run, i, .Pass, "")
}

// The pictures no node will read any more are let go: an output whose readers are all decided.
@(private = "file")
run_let_go :: proc(run: ^Run) {
	for &rn, i in run.nodes {
		if rn.state != .Done { continue }
		id := run.workflow.nodes[i].id
		for port in 0 ..< OUTPUTS_MAX {
			v := &rn.outputs[port]
			if v.picture == nil { continue }
			needed := false
			for l in run.workflow.links {
				if l.from_node != id || int(l.from_port) != port { continue }
				to := workflow_node_index(&run.workflow, l.to_node)
				if to >= 0 && run.nodes[to].state not_in NODE_STATE_DECIDED { needed = true }
			}
			if !needed {
				picture_release(v.picture)
				v.picture = nil
			}
		}
	}
}

// Whether a Condition sends its picture to "yes".
condition_holds :: proc(n: ^Workflow_Node, v: Run_Value, source: Source) -> bool {
	test := Condition_Test(node_int(n, "test"))
	if test == .Source { return int(source) == node_int(n, "source") }
	if v.picture == nil { return false }
	size := v.picture.shot.size
	have: f64
	switch test {
	case .Width:  have = f64(size.x)
	case .Height: have = f64(size.y)
	case .Aspect: have = size.y > 0 ? f64(size.x) / f64(size.y) : 0
	case .Source:
	}
	want := node_float(n, "value")
	switch Condition_Compare(node_int(n, "compare")) {
	case .More:  return have > want
	case .Less:  return have < want
	case .Equal: return abs(have - want) < 0.005
	}
	return false
}

////////////////////////////////
// What a run did, for its notification

Run_Summary :: struct {
	title:   string,
	body:    string,
	failed:  bool,   // a node failed: the notification is shown even with no Notify node
	notify:  bool,   // a Notify node ran
	entries: int,    // the nodes that did something outside the picture
}

// The notification of a run: the title of its first Notify node, or one made of what it did (saved, uploaded, copied,
// read), and a body with the address, the file, the text read, or what failed. Temp allocator.
run_summary :: proc(run: ^Run) -> (s: Run_Summary) {
	path, url, text, problem: string
	copied_image, copied_text, read_qr, read_text, upload_failed, saved_failed: bool
	notify_title, notify_body: string
	for &rn, i in run.nodes {
		n := &run.workflow.nodes[i]
		if rn.state == .Failed {
			s.failed = true
			if problem == "" { problem = rn.message != "" ? rn.message : "a step failed" }
			#partial switch n.kind {
			case .Upload:    upload_failed = true
			case .Save_File: saved_failed = true
			}
			continue
		}
		if rn.state != .Done { continue }
		#partial switch n.kind {
		case .Save_File:  if path == "" { path = rn.outputs[0].text }; s.entries += 1
		case .Upload:     if url == "" { url = rn.outputs[0].text }; s.entries += 1
		case .Copy_Image: copied_image = true; s.entries += 1
		case .Copy_Text:  copied_text = true; s.entries += 1
		case .Read_Qr:    read_qr = true; if text == "" { text = rn.outputs[0].text }
		case .Read_Text:  read_text = true; if text == "" { text = rn.outputs[0].text }
		case .Notify:
			if !s.notify {
				s.notify = true
				notify_title = node_text(n, "title")
				if Notify_Show(node_int(n, "show")) == .Input { notify_body = run_notify_body(run, i) }
			}
		}
	}
	switch {
	case read_qr && copied_text:   s.title = "QR code copied"
	case read_qr:                  s.title = "QR code read"
	case read_text && copied_text: s.title = "Text copied"
	case read_text:                s.title = "Text read"
	case url != "":                s.title = path != "" ? "Screenshot saved and uploaded" : "Screenshot uploaded"
	case upload_failed && path != "": s.title = "Screenshot saved, not uploaded"
	case path != "" && copied_image: s.title = "Screenshot saved and copied"
	case path != "":               s.title = "Screenshot saved"
	case copied_image:             s.title = "Screenshot copied to the clipboard"
	case copied_text:              s.title = "Text copied"
	case s.failed && (saved_failed || s.entries == 0):
		s.title = run_has(run, .Read_Qr) ? "No QR code" : run_has(run, .Read_Text) ? "No text" : "No screenshot"
	case:                          s.title = "Done"
	}
	switch {
	case s.failed && s.entries == 0: s.body = problem
	case url != "":                  s.body = url
	case upload_failed:              s.body = problem
	case text != "":                 s.body = notice_text(text)
	case path != "":                 s.body = path
	case s.failed:                   s.body = problem
	}
	if notify_title != "" { s.title = notify_title }
	if notify_body != "" { s.body = notify_body }
	return
}

@(private = "file")
run_has :: proc(run: ^Run, kind: Node_Kind) -> bool {
	return workflow_has(&run.workflow, kind)
}

// What came into Notify node `i`, a line each (a picture says so; a text is cut).
@(private = "file")
run_notify_body :: proc(run: ^Run, i: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	id := run.workflow.nodes[i].id
	for l in run.workflow.links {
		if l.to_node != id { continue }
		from := workflow_node_index(&run.workflow, l.from_node)
		if from < 0 || run.nodes[from].state != .Done || int(l.from_port) not_in run.nodes[from].made { continue }
		v := run.nodes[from].outputs[l.from_port]
		line := v.kind == .Image ? "A picture" : notice_text(v.text)
		if line == "" { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}
