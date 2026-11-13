package cliche

// The app's part of the workflows: a capture's picture starts a run of the workflow its trigger runs; the run's tasks
// go where each must be done (workflow_run.odin says which are ready): the worker for pixels, files and the network
// (Job_Node, workflow_ops.odin), this thread for the clipboard and the history, an editor of its own for each Annotate.
// Several runs may be in flight: a capture while a run waits on its editor. A run that ends says what it did in one
// notification.

import "core:log"
import "core:strings"
import flowgraph "gt:flowgraph"
import "gt:platform"

// The Annotate node of a run an editor's picture is for (Editor.ask; run 0: none, as for a picture of the history).
Annotate_Ask :: struct {
	run:  u64,
	node: int,
}

// The workflows of the app, from the start: the defaults until the file is read (a capture at once runs them).
workflows_start :: proc(app: ^App) {
	app.workflows = workflows_default()
	worker_send(&app.worker, Job_Workflows_Load{})
}

workflows_stop :: proc(app: ^App) {
	for run in app.runs {
		run_free(run)
		free(run)
	}
	delete(app.runs)
	workflows_free(&app.workflows)
	delete(app.workflows_problem)
}

// The file read (or the defaults, and why).
workflows_loaded :: proc(app: ^App, r: Result_Workflows) {
	workflows_free(&app.workflows)
	app.workflows = r.workflows
	app.workflows.version += 1
	delete(app.workflows_problem)
	app.workflows_problem = r.problem
	app.workflows_loaded = true
	workflow_view_reset(app)
	// (the defaults that stand for a broken file are written: the next start reads them)
	if r.problem != "" {
		app.workflows_save_due = true
		workflows_save(app)
	}
}

// The workflows changed: what is made from them is made again; the file is written when the gesture ends (`now`), or a
// little after the last change of a parameter dragged (workflow_view.odin calls workflows_save then).
workflows_changed :: proc(app: ^App, now: bool) {
	app.workflows.version += 1
	app.workflows_save_due = true
	if now { workflows_save(app) }
}

// The file written on the worker. Its text is made here, once per change (a few kilobytes), not per frame.
workflows_save :: proc(app: ^App) {
	if !app.workflows_save_due { return }
	app.workflows_save_due = false
	worker_send(&app.worker, Job_Write{path = strings.clone(workflows_file()), text = workflows_text(&app.workflows)})
}

// Whether an editor is opened ahead (app_prewarm): a screenshot's workflow opens one.
workflows_want_editor :: proc(app: ^App) -> bool {
	for t in ([]Trigger{.Region, .Screen, .Window}) {
		if wf := workflows_for(&app.workflows, t); wf != nil && workflow_has(wf, .Annotate) { return true }
	}
	return false
}

////////////////////////////////
// Runs

// A capture's picture (taken) runs the workflow of `t`. False: no workflow runs for it (the shot is freed).
workflow_capture :: proc(app: ^App, t: Trigger, shot: Shot) -> bool {
	wf := workflows_for(&app.workflows, t)
	if wf == nil {
		shot := shot
		shot_free(&shot)
		return false
	}
	workflow_run_start(app, wf, shot, {source = shot.source})
	return true
}

// Starts a run of `wf` (copied) on `shot` (taken). `start.id` and `start.workflow` are given here.
workflow_run_start :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, shot: Shot, start: Run_Start) {
	start := start
	app.run_next_id += 1
	start.id, start.workflow = app.run_next_id, wf.id
	run := new(Run)
	run_start(run, wf.graph, shot, start)
	append(&app.runs, run)
	workflow_view_run_started(app, run)
	// (the Capture node's thumbnail: its picture made smaller on the worker, as every other node's)
	if workflow_view_wants(app, run) {
		for n, i in run.flow.graph.nodes {
			if Node_Kind(n.kind) != .Capture { continue }
			worker_send(&app.worker, Job_Thumbnail{run = run.flow.id, node = i, input = flowgraph.value_hold(run.picture)})
			break
		}
	}
	workflow_pump(app, run)
}

@(private = "file")
workflow_run_find :: proc(app: ^App, id: u64) -> ^Run {
	for run in app.runs { if run.flow.id == id { return run } }
	return nil
}

// The tasks ready, each sent where it is done; again while this thread finishes some at once. Then the end, when
// nothing is left to run.
@(private = "file")
workflow_pump :: proc(app: ^App, run: ^Run) {
	for {
		tasks := run_tasks(run)
		if len(tasks) == 0 { break }
		for task in tasks {
			switch Node_Place(CATALOG.nodes[task.kind].place) {
			case .Worker:
				n := &run.flow.graph.nodes[task.node]
				input, _ := flowgraph.task_input(task, 0)
				worker_send(&app.worker, Job_Node{
					run = run.flow.id, node = task.node, n = flowgraph.node_clone(n^), input = flowgraph.value_hold(input),
					source = run.source, defaults = workflow_defaults(app, n), thumbnail = workflow_view_wants(app, run),
				})
			case .Interface:
				// (its message is a constant: run_finish keeps a copy)
				flowgraph.run_finish(&run.flow, task.node, workflow_interface_task(app, run, task))
			case .Editor:
				workflow_annotate_open(app, run, task)
			case .Run:
				// (run_tasks decided it: none comes here)
			}
		}
	}
	workflow_view_follow(app, run)
	if flowgraph.run_over(&run.flow) { workflow_run_end(app, run) }
}

// What a node takes from the settings when its own parameter is empty.
@(private = "file")
workflow_defaults :: proc(app: ^App, n: ^flowgraph.Node) -> Node_Defaults {
	d: Node_Defaults
	#partial switch Node_Kind(n.kind) {
	case .Save_File:
		d.folder = strings.clone(app.settings.folder)
		d.pattern = strings.clone(app.settings.name_pattern)
	case .Upload:
		d.uploader = strings.clone(app.settings.uploader)
		d.pattern = strings.clone(app.settings.name_pattern)
	case .Read_Text:
		d.languages = strings.clone(app.settings.ocr_languages)
	}
	return d
}

// The work of a node on this thread: the clipboard (the anchor's: it outlives every window), the history. A Notify node
// only marks the run: its notification is the run's, at the end.
@(private = "file")
workflow_interface_task :: proc(app: ^App, run: ^Run, task: flowgraph.Task) -> (r: flowgraph.Result) {
	#partial switch Node_Kind(task.kind) {
	case .Copy_Text:
		v, _ := flowgraph.task_input(task, 0)
		d := run_data(v)
		if d == nil || !platform.clipboard_set(app.anchor, {text = d.text}) { return {outcome = .Failed, message = "the text cannot go to the clipboard"} }
		// (the same text goes on, as a text: an address or a path copied reads as one)
		r.outputs[0] = flowgraph.value_hold(v)
		r.outputs[0].kind = PORT_TEXT
	case .Notify:
	case .Add_To_History:
		workflow_history_note(app, run, task.inputs)
	case:
		r = {outcome = .Failed, message = "this step cannot run here"}
	}
	return
}

// What came into an Add to history node, kept: a file, an address, a text read. A picture alone is not kept: it would
// be nothing to find again.
@(private = "file")
workflow_history_note :: proc(app: ^App, run: ^Run, inputs: []flowgraph.Input) {
	e := History_Entry{kind = history_kind_of(run.source)}
	for input in inputs {
		d := run_data(input.value)
		if d == nil { continue }
		switch input.value.kind {
		case PORT_FILE:
			if e.path == "" { e.path, e.size, e.bytes = d.text, d.size, d.bytes }
		case PORT_URL:
			if e.url == "" { e.url = d.text }
		case PORT_TEXT:
			if e.text == "" {
				e.text = d.text
				if d.origin == .Read_Qr { e.kind = .Qr }
				if d.origin == .Read_Text { e.kind = .Text }
			}
		case PORT_IMAGE:
			if e.size == {} { e.size = d.shot.size }
		}
	}
	if e.path == "" && e.url == "" && e.text == "" { return }
	app.notice_entry = history_note(app, e)
}

// A thumbnail made on the worker for a node that is not run there (Capture): to the Workflows mode.
workflow_thumbnail_result :: proc(app: ^App, r: Result_Thumbnail) {
	if run := workflow_run_find(app, r.run); run != nil { workflow_view_thumbnail(app, run, r.node, r.thumbnail, r.thumbnail_size) }
	delete(r.thumbnail)
}

// A node's result from the worker: given to its run (gone meanwhile: freed), its thumbnail to the Workflows mode.
workflow_node_result :: proc(app: ^App, r: Result_Node) {
	r := r
	run := workflow_run_find(app, r.run)
	if run == nil {
		result_node_free(&r)
		return
	}
	workflow_view_thumbnail(app, run, r.node, r.thumbnail, r.thumbnail_size)
	delete(r.thumbnail)
	r.thumbnail = nil
	if r.clipboard_png != nil {
		// Copy image: its PNG made on the worker; the clipboard is the anchor's (it outlives every window)
		d := run_data(r.input)
		if d != nil && platform.clipboard_set_image(app.anchor, {rgba = d.shot.rgba, size = d.shot.size, png = r.clipboard_png}) {
			r.result.outputs[0] = flowgraph.value_hold(r.input)
		} else {
			r.result = {outcome = .Failed, message = strings.clone("the picture cannot go to the clipboard")}
		}
		delete(r.clipboard_png)
		r.clipboard_png = nil
	}
	flowgraph.run_finish(&run.flow, r.node, r.result)   // (its outputs are the run's now)
	r.result.outputs = {}
	delete(r.result.message)
	flowgraph.value_release(&r.input)
	workflow_pump(app, run)
}

// The run is over: told in one notification (not for a preview), then let go.
@(private = "file")
workflow_run_end :: proc(app: ^App, run: ^Run) {
	if !run.preview {
		s := run_summary(run)
		if s.failed { log.warnf("%s: %s", s.title, s.body) }
		if s.notify || s.failed { app_announce(app, s.failed ? .Bad : .Good, s.title, s.body) }
	}
	workflow_view_run_ended(app, run)
	for r, i in app.runs {
		if r == run {
			ordered_remove(&app.runs, i)
			break
		}
	}
	run_free(run)
	free(run)
}

// The preview of the Workflows mode: `wf` run on the newest picture of the history, with its effects off. The picture
// is read and decoded on the worker (Result_Picture). False: the history holds no picture.
workflow_preview :: proc(app: ^App, wf: ^flowgraph.Graph_Entry) -> bool {
	h := &app.history_window.history
	for i := len(h.entries) - 1; i >= 0; i -= 1 {
		e := h.entries[i]
		if e.path == "" || e.missing || !(e.kind == .Region || e.kind == .Screen || e.kind == .Window) { continue }
		worker_send(&app.worker, Job_Picture_Load{path = strings.clone(e.path), workflow = wf.id})
		return true
	}
	return false
}

workflow_preview_picture :: proc(app: ^App, r: Result_Picture) {
	r := r
	wf := workflows_find(&app.workflows, r.workflow)
	if !r.ok || wf == nil {
		shot_free(&r.shot)
		workflow_view_status(app, r.ok ? "" : "The newest capture of the history cannot be read.")
		return
	}
	workflow_run_start(app, wf, r.shot, {source = r.shot.source, preview = true})
}

////////////////////////////////
// Annotate: an editor for each picture

// An Annotate node opens its picture in an editor of its own, at once: any number are open together, and none waits
// for another's Done. The editor's Done or Cancel ends this node (workflow_editor_done, workflow_editor_closed): its
// "done" or its "cancelled" action fires.
@(private = "file")
workflow_annotate_open :: proc(app: ^App, run: ^Run, task: flowgraph.Task) {
	v, _ := flowgraph.task_input(task, 0)
	d := run_data(v)
	if d == nil {
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = "no picture came in"})
		return
	}
	// (the editor owns a copy: the run's picture may feed other branches meanwhile)
	shot := d.shot
	shot.rgba = clone_bytes(shot.rgba)
	ed := editor_take(app)
	if ed == nil {
		shot_free(&shot)
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = "the editor cannot open"})
		return
	}
	if !editor_open_shot(ed, shot, shot.scale > 0 ? shot.scale : 1) {
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = "the editor cannot open"})
		return
	}
	ed.ask = {run.flow.id, task.node}
}

// An editor's Done: its picture (taken) goes on in the run's branch it came for (`ask`); a picture of the history runs
// the workflow of "Capture a region and edit" (its Annotate passes the picture on: it is annotated already).
workflow_editor_done :: proc(app: ^App, ask: Annotate_Ask, shot: Shot) {
	if ask.run == 0 {
		wf := workflows_for(&app.workflows, .Edit)
		if wf == nil { wf = workflows_for(&app.workflows, .Region) }
		if wf == nil {
			shot := shot
			shot_free(&shot)
			workflow_no_workflow(app)
		} else {
			workflow_run_start(app, wf, shot, {source = shot.source, annotated = true})
		}
	} else if run := workflow_run_find(app, ask.run); run != nil {
		r: flowgraph.Result
		r.outputs[0] = run_value(PORT_IMAGE, {shot = shot, origin = .Annotate})
		flowgraph.run_finish(&run.flow, ask.node, r)
		workflow_pump(app, run)
	} else {
		shot := shot
		shot_free(&shot)
	}
}

// An editor cancelled (its Cancel, or closed without Done): the run's Annotate it came for (`ask`) is Cancelled. What
// needs its picture or its "done" is skipped; what hangs on its "cancelled" runs.
workflow_editor_closed :: proc(app: ^App, ask: Annotate_Ask) {
	if ask.run == 0 { return }
	if run := workflow_run_find(app, ask.run); run != nil && flowgraph.run_cancel(&run.flow, ask.node, "cancelled in the editor") { workflow_pump(app, run) }
}

// No workflow runs for this capture: said, so the user knows where to choose one.
workflow_no_workflow :: proc(app: ^App) {
	body := FLOW_ERROR_TEXT[.No_Workflow]
	log.warn(body)
	app_announce(app, .Warn, "Nothing ran", body)
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
