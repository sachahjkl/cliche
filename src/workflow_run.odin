package cliche

// A run of a workflow: a flowgraph.Run (docs/flowgraph.md of the toolkit) and what cliche adds to it, pure, on the
// interface's thread, tested without a window (workflow_run_test.odin). The app (workflow_app.odin) gives it a picture,
// takes the tasks that are ready (run_tasks), does each one where its kind says (a job of the worker, the clipboard
// here, the editor) and gives back how each ended (flowgraph.run_finish, run_cancel). The run ends when every node is
// decided (flowgraph.run_over); run_summary then says what it did, for one notification.
//
// Each node of a run is flowgraph's small state machine (flowgraph.node_step): Waiting, then Running when its inputs
// came, then Done, Failed or Cancelled (the editor closed without Done); Skipped when an input it waits for never comes,
// or an effect in a preview. What cliche decides at once is a task finished here (run_tasks): Capture gives the
// picture taken, a Condition gives it on "yes" or on "no" only (what hangs on the other is Skipped), an Annotate passes
// it on in a preview or for a picture that comes from the editor already.
//
// Values are shared, read only: fan-out gives each branch the same picture, and a node that changes it makes a new one
// (workflow_ops.odin). A value's data is a Run_Data; a picture is let go when every node that reads it is decided and no
// job holds it.

import "core:strings"
import flowgraph "gt:flowgraph"
import i18n "gt:i18n"

// What a value holds (flowgraph.Value's data): a picture, or a text (an address, a file's path).
Run_Data :: struct {
	shot:   Shot,        // PORT_IMAGE (owned)
	text:   string,      // PORT_TEXT, PORT_URL (the address), PORT_FILE (the path); owned
	origin: Node_Kind,   // the node that made it (the history's kind of a text: a QR code's, a text read)
	size:   [2]int,      // PORT_FILE: the picture's, in pixels
	bytes:  i64,         // PORT_FILE: the file's
}

// A value of `kind` holding `d` (taken): one reference, the caller's.
run_value :: proc(kind: flowgraph.Port_Kind, d: Run_Data) -> flowgraph.Value {
	data := new(Run_Data)
	data^ = d
	return flowgraph.value_make(kind, data, run_data_free)
}

// What `v` holds (nil: nothing, as a picture let go).
run_data :: proc(v: flowgraph.Value) -> ^Run_Data {
	return flowgraph.value_data(v, Run_Data)
}

// (the last release frees it, on whichever thread: the worker's too)
@(private = "file")
run_data_free :: proc(data: rawptr) {
	d := (^Run_Data)(data)
	shot_free(&d.shot)
	delete(d.text)
	free(d)
}

Run :: struct {
	flow:      flowgraph.Run,
	workflow:  u64,               // the workflow's id
	source:    Source,
	preview:   bool,              // the effects are off (the clipboard, files, uploads, notifications, the history)
	annotated: bool,              // the picture comes from the editor already: Annotate passes it on
	picture:   flowgraph.Value,   // the capture's, until the Capture node gives it
}

Run_Start :: struct {
	id:        u64,
	workflow:  u64,
	source:    Source,
	preview:   bool,
	annotated: bool,
}

// Starts a run of `g` (copied) on `shot` (taken): the Capture node gives it. A workflow with no Capture node has nothing
// to run: every node is Skipped.
run_start :: proc(run: ^Run, g: flowgraph.Graph, shot: Shot, start: Run_Start) {
	run^ = {workflow = start.workflow, source = start.source, preview = start.preview, annotated = start.annotated}
	flowgraph.run_init(&run.flow, g, &CATALOG, {id = start.id, dry = start.preview})
	run.picture = run_value(PORT_IMAGE, {shot = shot, origin = .Capture})
}

run_free :: proc(run: ^Run) {
	flowgraph.run_destroy(&run.flow)
	flowgraph.value_release(&run.picture)
	run^ = {}
}

// The tasks ready for the app, now Running: the app does each one and ends it (flowgraph.run_finish, run_cancel). What
// the run decides itself is done here first, until nothing more changes. Temp allocator.
run_tasks :: proc(run: ^Run) -> []flowgraph.Task {
	out := make([dynamic]flowgraph.Task, 0, 4, context.temp_allocator)
	for {
		decided := false
		for task in flowgraph.run_next(&run.flow) {
			if run_decide(run, task) { decided = true } else { append(&out, task) }
		}
		if !decided { break }
	}
	return out[:]
}

// The node of `task` finished at once when the run decides it (Capture, Condition, Annotate passed through). False: the
// app does it.
@(private = "file")
run_decide :: proc(run: ^Run, task: flowgraph.Task) -> bool {
	r: flowgraph.Result
	input, _ := flowgraph.task_input(task, 0)
	#partial switch Node_Kind(task.kind) {
	case .Capture:
		if run.picture.payload == nil {
			r = {outcome = .Failed, message = i18n.tr("no picture came in")}
		} else {
			r.outputs[0] = run.picture   // (taken: let go as soon as the nodes that read it are decided)
			run.picture = {}
		}
	case .Condition:
		r.outputs[condition_holds(&run.flow.graph.nodes[task.node], input, run.source) ? 0 : 1] = flowgraph.value_hold(input)
	case .Annotate:
		// (the editor is not opened for a preview; a picture from the editor is annotated already)
		if !run.preview && !run.annotated { return false }
		r.outputs[0] = flowgraph.value_hold(input)
	case:
		return false
	}
	flowgraph.run_finish(&run.flow, task.node, r)
	return true
}

// Whether a Condition sends its picture to "yes".
condition_holds :: proc(n: ^flowgraph.Node, v: flowgraph.Value, source: Source) -> bool {
	test := Condition_Test(flowgraph.param_int(&CATALOG, n, "test"))
	if test == .Source { return int(source) == flowgraph.param_int(&CATALOG, n, "source") }
	d := run_data(v)
	if d == nil { return false }
	size := d.shot.size
	have: f64
	switch test {
	case .Width:  have = f64(size.x)
	case .Height: have = f64(size.y)
	case .Aspect: have = size.y > 0 ? f64(size.x) / f64(size.y) : 0
	case .Source:
	}
	want := flowgraph.param_float(&CATALOG, n, "value")
	switch Condition_Compare(flowgraph.param_int(&CATALOG, n, "compare")) {
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
	for &rn, i in run.flow.nodes {
		n := &run.flow.graph.nodes[i]
		kind := Node_Kind(n.kind)
		if rn.state == .Failed {
			s.failed = true
			if problem == "" { problem = rn.message != "" ? rn.message : i18n.tr("a step failed") }
			#partial switch kind {
			case .Upload:    upload_failed = true
			case .Save_File: saved_failed = true
			}
			continue
		}
		if rn.state != .Done { continue }
		#partial switch kind {
		case .Save_File:  if path == "" { path = output_text(&rn, 0) }; s.entries += 1
		case .Upload:     if url == "" { url = output_text(&rn, 0) }; s.entries += 1
		case .Copy_Image: copied_image = true; s.entries += 1
		case .Copy_Text:  copied_text = true; s.entries += 1
		case .Read_Qr:    read_qr = true; if text == "" { text = output_text(&rn, 0) }
		case .Read_Text:  read_text = true; if text == "" { text = output_text(&rn, 0) }
		case .Notify:
			if !s.notify {
				s.notify = true
				notify_title = flowgraph.param_text(&CATALOG, n, "title")
				if Notify_Show(flowgraph.param_int(&CATALOG, n, "show")) == .Input { notify_body = run_notify_body(run, i) }
			}
		}
	}
	switch {
	case read_qr && copied_text:   s.title = i18n.tr("QR code copied")
	case read_qr:                  s.title = i18n.tr("QR code read")
	case read_text && copied_text: s.title = i18n.tr("Text copied")
	case read_text:                s.title = i18n.tr("Text read")
	case url != "":                s.title = path != "" ? i18n.tr("Screenshot saved and uploaded") : i18n.tr("Screenshot uploaded")
	case upload_failed && path != "": s.title = i18n.tr("Screenshot saved, not uploaded")
	case path != "" && copied_image: s.title = i18n.tr("Screenshot saved and copied")
	case path != "":               s.title = i18n.tr("Screenshot saved")
	case copied_image:             s.title = i18n.tr("Screenshot copied to the clipboard")
	case copied_text:              s.title = i18n.tr("Text copied")
	case s.failed && (saved_failed || s.entries == 0):
		s.title = run_has(run, .Read_Qr) ? i18n.tr("No QR code") : run_has(run, .Read_Text) ? i18n.tr("No text") : i18n.tr("No screenshot")
	case:                          s.title = i18n.tr("Done")
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

// The text of output `port` of a node that is done ("": none).
@(private = "file")
output_text :: proc(rn: ^flowgraph.Run_Node, port: int) -> string {
	if !rn.outputs[port].made { return "" }
	d := run_data(rn.outputs[port].value)
	return d != nil ? d.text : ""
}

@(private = "file")
run_has :: proc(run: ^Run, kind: Node_Kind) -> bool {
	return flowgraph.graph_count(&run.flow.graph, int(kind)) > 0
}

// What came into Notify node `i`, a line each (a picture says so; a text is cut).
@(private = "file")
run_notify_body :: proc(run: ^Run, i: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	g := &run.flow.graph
	id := g.nodes[i].id
	for l in g.links {
		if l.to_node != id { continue }
		from := flowgraph.graph_node_index(g, l.from_node)
		if from < 0 || run.flow.nodes[from].state != .Done || int(l.from_port) >= flowgraph.PORTS_MAX { continue }
		o := run.flow.nodes[from].outputs[l.from_port]
		if !o.made { continue }   // (an action, or an output the node did not give)
		line: string
		if o.value.kind == PORT_IMAGE {
			line = i18n.tr("A picture")
		} else if d := run_data(o.value); d != nil {
			line = notice_text(d.text)
		}
		if line == "" { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}
