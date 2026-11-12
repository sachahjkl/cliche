package cliche

// The app's part of the workflows: a capture's picture starts a run of the workflow its trigger runs; the run's tasks
// go where each must be done (workflow_run.odin says which are ready): the worker for pixels, files and the network
// (Job_Node, workflow_ops.odin), this thread for the clipboard and the history, the editor for Annotate. Several runs may
// be in flight: a capture while a run waits on the editor. A run that ends says what it did in one notification.

import "core:fmt"
import "core:strings"
import "gt:platform"

// An Annotate node of a run, waiting for the editor (run 0: none, as for a picture of the history).
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
	delete(app.annotate_queue)
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
	if r.problem != "" { workflows_save(app) }
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

// Whether the editor is opened ahead (app_prewarm): a screenshot's workflow opens it.
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
	workflow_run_start(app, wf^, shot, {source = shot.source})
	return true
}

// Starts a run of `wf` (copied) on `shot` (taken). `start.id` is given here.
workflow_run_start :: proc(app: ^App, wf: Workflow, shot: Shot, start: Run_Start) {
	start := start
	app.run_next_id += 1
	start.id = app.run_next_id
	run := new(Run)
	run_start(run, wf, shot, start)
	append(&app.runs, run)
	workflow_view_run_started(app, run)
	workflow_pump(app, run)
}

@(private = "file")
workflow_run_find :: proc(app: ^App, id: u64) -> ^Run {
	for run in app.runs { if run.id == id { return run } }
	return nil
}

// The tasks ready, each sent where it is done; again while this thread finishes some at once. Then the end, when
// nothing is left to run.
@(private = "file")
workflow_pump :: proc(app: ^App, run: ^Run) {
	for {
		tasks := run_next(run)
		if len(tasks) == 0 { break }
		for task in tasks {
			switch NODE_DEFS[task.kind].place {
			case .Worker:
				n := node_clone(run.workflow.nodes[task.node])
				input: Run_Value
				if len(task.inputs) > 0 { input = value_clone(task.inputs[0]) }
				worker_send(&app.worker, Job_Node{
					run = run.id, node = task.node, n = n, input = input, source = run.source,
					defaults = workflow_defaults(app, &run.workflow.nodes[task.node]),
					thumbnail = workflow_view_wants(app, run),
				})
			case .Interface:
				// (its message is a constant: run_finish keeps a copy)
				run_finish(run, task.node, workflow_interface_task(app, run, task))
			case .Editor:
				workflow_annotate_ask(app, run, task)
			case .Run:
			}
		}
	}
	workflow_view_follow(app, run)
	if run_over(run) { workflow_run_end(app, run) }
}

// What a node takes from the settings when its own parameter is empty.
@(private = "file")
workflow_defaults :: proc(app: ^App, n: ^Workflow_Node) -> Node_Defaults {
	d: Node_Defaults
	#partial switch n.kind {
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
workflow_interface_task :: proc(app: ^App, run: ^Run, task: Run_Task) -> (r: Run_Result) {
	#partial switch task.kind {
	case .Copy_Image:
		v := task.inputs[0]
		if v.picture == nil { return {message = "no picture came in"} }
		// (gt:platform encodes the clipboard's PNG on this thread, at its fast level: it takes no encoded file)
		if !platform.clipboard_set_image(app.anchor, {rgba = v.picture.shot.rgba, size = v.picture.shot.size}) {
			return {message = "the picture cannot go to the clipboard"}
		}
		r = {ok = true, made = {0}}
		r.outputs[0] = value_clone(v)
	case .Copy_Text:
		v := task.inputs[0]
		if !platform.clipboard_set(app.anchor, {text = v.text}) { return {message = "the text cannot go to the clipboard"} }
		r = {ok = true, made = {0}}
		r.outputs[0] = value_clone(v)
		r.outputs[0].kind = .Text
	case .Notify:
		r = {ok = true}
	case .Add_To_History:
		workflow_history_note(app, run, task.inputs)
		r = {ok = true}
	case:
		r = {message = "this step cannot run here"}
	}
	return
}

// What came into an Add to history node, kept: a file, an address, a text read. A picture alone is not kept: it would
// be nothing to find again.
@(private = "file")
workflow_history_note :: proc(app: ^App, run: ^Run, inputs: []Run_Value) {
	e := History_Entry{kind = history_kind_of(run.source)}
	for v in inputs {
		switch v.kind {
		case .File:
			if e.path == "" { e.path, e.size, e.bytes = v.text, v.size, v.bytes }
		case .Url:
			if e.url == "" { e.url = v.text }
		case .Text:
			if e.text == "" {
				e.text = v.text
				if v.origin == .Read_Qr { e.kind = .Qr }
				if v.origin == .Read_Text { e.kind = .Text }
			}
		case .Image, .Any:
			if v.picture != nil && e.size == {} { e.size = v.picture.shot.size }
		}
	}
	if e.path == "" && e.url == "" && e.text == "" { return }
	app.notice_entry = history_note(app, e)
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
	run_finish(run, r.node, r.result)   // (its outputs are the run's now)
	r.result.outputs = {}
	delete(r.result.message)
	picture_release(r.input)
	workflow_pump(app, run)
}

// The run is over: told in one notification (not for a preview), then let go.
@(private = "file")
workflow_run_end :: proc(app: ^App, run: ^Run) {
	if !run.preview {
		s := run_summary(run)
		if s.failed { fmt.eprintfln("cliche: %s: %s", s.title, s.body) }
		if s.notify || s.failed {
			if id, ok := platform.notify(app.anchor, {title = s.title, body = s.body, silent = true, replace = app.notice}); ok { app.notice = id }
		}
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
workflow_preview :: proc(app: ^App, wf: ^Workflow) -> bool {
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
	workflow_run_start(app, wf^, r.shot, {source = r.shot.source, preview = true})
}

////////////////////////////////
// Annotate: the editor

// An Annotate node waits for the editor: shown now when the editor is free, else when the picture it holds is done.
@(private = "file")
workflow_annotate_ask :: proc(app: ^App, run: ^Run, task: Run_Task) {
	append(&app.annotate_queue, Annotate_Ask{run.id, task.node})
	workflow_annotate_next(app)
}

// The editor takes the next Annotate waiting when it is free: no picture, or one of the history left unchanged.
workflow_annotate_next :: proc(app: ^App) {
	ed := &app.editor
	for len(app.annotate_queue) > 0 {
		if app.editor_for.run != 0 { return }
		if ed.has_picture && edit_changed(&ed.model) { return }
		ask := app.annotate_queue[0]
		ordered_remove(&app.annotate_queue, 0)
		run := workflow_run_find(app, ask.run)
		if run == nil || ask.node >= len(run.nodes) || run.nodes[ask.node].state != .Waiting { continue }
		v := workflow_annotate_input(run, ask.node)
		if v.picture == nil {
			run_finish(run, ask.node, {message = "no picture came in"})
			workflow_pump(app, run)
			continue
		}
		// (the editor owns a copy: the run's picture may feed other branches meanwhile)
		shot := v.picture.shot
		shot.rgba = clone_bytes(shot.rgba)
		app.editor_for = ask
		if !editor_open_shot(app, shot, shot.scale > 0 ? shot.scale : 1) {
			app.editor_for = {}
			run_finish(run, ask.node, {message = "the editor cannot open"})
			workflow_pump(app, run)
		}
		return
	}
}

// The value that comes into Annotate node `node` (its single input).
@(private = "file")
workflow_annotate_input :: proc(run: ^Run, node: int) -> Run_Value {
	id := run.workflow.nodes[node].id
	for l in run.workflow.links {
		if l.to_node != id { continue }
		from := workflow_node_index(&run.workflow, l.from_node)
		if from >= 0 && run.nodes[from].state == .Done && int(l.from_port) in run.nodes[from].made { return run.nodes[from].outputs[l.from_port] }
	}
	return {}
}

// The editor's Done: its picture (taken) goes on in the run that asked for it; a picture of the history runs the
// workflow of "Capture a region and edit" (its Annotate passes the picture on: it is annotated already).
workflow_editor_done :: proc(app: ^App, shot: Shot) {
	ask := app.editor_for
	app.editor_for = {}
	if ask.run == 0 {
		wf := workflows_for(&app.workflows, .Edit)
		if wf == nil { wf = workflows_for(&app.workflows, .Region) }
		if wf == nil {
			shot := shot
			shot_free(&shot)
			workflow_no_workflow(app)
		} else {
			workflow_run_start(app, wf^, shot, {source = shot.source, annotated = true})
		}
	} else if run := workflow_run_find(app, ask.run); run != nil {
		r := Run_Result{ok = true, made = {0}}
		r.outputs[0] = {kind = .Image, picture = picture_make(shot), origin = .Annotate}
		run_finish(run, ask.node, r)
		workflow_pump(app, run)
	} else {
		shot := shot
		shot_free(&shot)
	}
	workflow_annotate_next(app)
}

// The editor closed without Done: its branch of the run stops there.
workflow_editor_closed :: proc(app: ^App) {
	ask := app.editor_for
	app.editor_for = {}
	if ask.run != 0 {
		if run := workflow_run_find(app, ask.run); run != nil && run_cancel(run, ask.node, "closed without Done") { workflow_pump(app, run) }
	}
	workflow_annotate_next(app)
}

// No workflow runs for this capture: said, so the user knows where to choose one.
workflow_no_workflow :: proc(app: ^App) {
	body := FLOW_ERROR_TEXT[.No_Workflow]
	fmt.eprintfln("cliche: %s", body)
	if id, ok := platform.notify(app.anchor, {title = "Nothing ran", body = body, silent = true, replace = app.notice}); ok { app.notice = id }
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
