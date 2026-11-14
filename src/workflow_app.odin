package cliche

// The app's part of the workflows: a capture's picture starts a run of the workflow its trigger runs; the run's tasks
// go where each must be done (workflow_run.odin says which are ready): the worker for pixels, files and the network
// (Job_Node, workflow_ops.odin), this thread for the clipboard and the history, an editor of its own for each Annotate.
// Several runs may be in flight: a capture while a run waits on its editor. A run that ends says what it did in one
// notification; a click on it opens the address or the file the run made.
//
// A run may also start from what is no capture: the clipboard (a picture, files, a text: read without waiting,
// clipboard_request, its answer an event of the anchor) or files chosen in the system's dialog (on a chore: the dialog
// waits for the person). The worker makes the values (a picture decoded, a file looked at: Job_Run_Input), and each
// starts a run of the workflow of its trigger. An Ask node's question is a notification with Yes and No; its answer is
// an event of the anchor too (Questions, workflow_run.odin).

import "core:log"
import "core:strings"
import "core:sync"
import flowgraph "gt:flowgraph"
import "gt:platform"
import i18n "gt:i18n"
import tasks "gt:tasks"
import "gt:ui"

// The Annotate node of a run an editor's picture is for (Editor.ask; run 0: none, as for a picture of the history).
Annotate_Ask :: struct {
	run:  u64,
	node: int,
}

// What the runs need beside them, on the interface's thread (but what `files` points to): the Ask nodes' questions, the
// clipboard's read in flight, the files the dialog gave, what a click on the last notification opens.
Workflow_Desk :: struct {
	questions:     Questions,
	clip_id:       u64,                           // the clipboard_request answered next (0: none in flight)
	clip_workflow: u64,                           // the workflow it is read for
	clip_formats:  platform.Clipboard_Formats,    // what the clipboard said it holds when asked
	clip_tried:    platform.Clipboard_Formats,
	files:         ^Files_Box,                    // what the files' dialog gives back (nil: never opened)
	notice_open:   string,                        // the last run's address or file (owned; "": its history entry)
	notice_url:    bool,
}

// Where the files' dialog, on a chore, leaves the files chosen. Shared by the app and the chore (counted): a dialog still
// open when cliche ends finds it closed, not an app freed.
Files_Box :: struct {
	lock:     sync.Mutex,
	refs:     i32,               // (atomic)
	closed:   bool,              // guarded by `lock`: the app is ending; nothing is kept, no one is woken
	choosing: bool,              // guarded by `lock`: the dialog is open
	chosen:   [dynamic]string,   // guarded by `lock`: the files the dialog gave (owned)
	app:      ^App,              // woken under `lock` while not closed
}

@(private = "file")
files_box_release :: proc(b: ^Files_Box) {
	if sync.atomic_sub(&b.refs, 1) > 1 { return }
	for p in b.chosen { delete(p) }
	delete(b.chosen)
	free(b)
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
	d := &app.desk
	questions_destroy(&d.questions)
	// (a dialog still open hands its files to no one: the last of the two frees the box)
	if d.files != nil {
		sync.mutex_lock(&d.files.lock)
		d.files.closed = true
		sync.mutex_unlock(&d.files.lock)
		files_box_release(d.files)
		d.files = nil
	}
	delete(d.notice_open)
	d.notice_open = ""
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
	// (not for a workflow's own keys: "Edit then share" has some by default, and an editor at rest for everyone is a
	// renderer and a window held from the start; its editor opens at its first use, as `cliche --edit`'s does)
	return false
}

////////////////////////////////
// Runs

// A capture's picture (taken) runs the workflow of `target`. False: no workflow runs for it (the shot is freed).
workflow_capture :: proc(app: ^App, target: Capture_Target, shot: Shot) -> bool {
	wf := workflows_target(&app.workflows, target)
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
	workflow_run_start_value(app, wf, run_value(PORT_IMAGE, {shot = shot, origin = .Capture}), start)
}

// Starts a run of `wf` (copied) on `v` (taken: a picture, a file, a text).
workflow_run_start_value :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, v: flowgraph.Value, start: Run_Start) {
	start := start
	app.run_next_id += 1
	start.id, start.workflow = app.run_next_id, wf.id
	run := new(Run)
	run_start_value(run, wf.graph, v, start)
	append(&app.runs, run)
	workflow_view_run_started(app, run)
	// (the Capture node's thumbnail: its picture made smaller on the worker, as every other node's)
	if workflow_view_wants(app, run) {
		for n, i in run.flow.graph.nodes {
			if Node_Kind(n.kind) != .Capture { continue }
			if run.input.kind != PORT_IMAGE { break }   // (a file or a text has no thumbnail)
			worker_send(&app.worker, Job_Thumbnail{run = run.flow.id, node = i, input = flowgraph.value_hold(run.input)})
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
			case .Question:
				workflow_ask(app, run, task)
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
		if d == nil || !platform.clipboard_set(app.anchor, {text = d.text}) { return {outcome = .Failed, message = i18n.tr("the text cannot go to the clipboard")} }
		// (the same text goes on, as a text: an address or a path copied reads as one)
		r.outputs[0] = flowgraph.value_hold(v)
		r.outputs[0].kind = PORT_TEXT
	case .Notify:
	case .Add_To_History:
		workflow_history_note(app, run, task.inputs)
	case .Pin:
		v, _ := flowgraph.task_input(task, 0)
		d := run_data(v)
		if d == nil || d.shot.rgba == nil || !workflow_pin(app, d.shot) { return {outcome = .Failed, message = i18n.tr("the picture cannot be pinned")} }
	case:
		r = {outcome = .Failed, message = i18n.tr("this step cannot run here")}
	}
	return
}

// What came into an Add to history node, kept: a file, an address, a text read. A picture alone is not kept: it would
// be nothing to find again.
@(private = "file")
workflow_history_note :: proc(app: ^App, run: ^Run, inputs: []flowgraph.Input) {
	e := History_Entry{kind = history_kind_of(run.source)}
	// (what is no capture's: a picture of the clipboard, a file, a text)
	if run.origin != .Capture {
		switch run.given {
		case PORT_IMAGE: e.kind = .Picture
		case PORT_FILE:  e.kind = .File
		case:            e.kind = .Text
		}
	}
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
			r.result = {outcome = .Failed, message = strings.clone(i18n.tr("the picture cannot go to the clipboard"))}
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
		if s.notify || s.failed {
			app_announce(app, s.failed ? .Bad : .Good, s.title, s.body)
			// (what its click opens, kept after the announce, which forgets the one before: each notification
			// replaces the last, so the last one said is the one there)
			d := &app.desk
			d.notice_open, d.notice_url = strings.clone(s.open), s.open_url
		}
	}
	questions_forget_run(&app.desk.questions, run.flow.id)
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
		if e.path == "" || e.missing || !history_kind_picture(e.kind) { continue }
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
		workflow_view_status(app, r.ok ? "" : i18n.tr("The newest capture of the history cannot be read."))
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
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = i18n.tr("no picture came in")})
		return
	}
	// (the editor owns a copy: the run's picture may feed other branches meanwhile)
	shot := d.shot
	shot.rgba = clone_bytes(shot.rgba)
	ed := editor_take(app)
	if ed == nil {
		shot_free(&shot)
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = i18n.tr("the editor cannot open")})
		return
	}
	if !editor_open_shot(ed, shot, shot.scale > 0 ? shot.scale : 1) {
		flowgraph.run_finish(&run.flow, task.node, {outcome = .Failed, message = i18n.tr("the editor cannot open")})
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
	if run := workflow_run_find(app, ask.run); run != nil && flowgraph.run_cancel(&run.flow, ask.node, i18n.tr("cancelled in the editor")) { workflow_pump(app, run) }
}

// No workflow runs for this capture: said, so the user knows where to choose one.
workflow_no_workflow :: proc(app: ^App) {
	body := FLOW_ERROR_TEXT[.No_Workflow]
	log.warn(body)
	app_announce(app, .Warn, i18n.tr("Nothing ran"), i18n.tr(body))
}

////////////////////////////////
// Ask: a question in a notification

// An Ask node asks its question in a notification of its own, Yes and No its buttons; the run waits for the answer
// (workflow_anchor_event). The question is noted before the notification is sent: on Windows the system answers
// before notify_async returns.
@(private = "file")
workflow_ask :: proc(app: ^App, run: ^Run, task: flowgraph.Task) {
	q := flowgraph.param_text(&CATALOG, &run.flow.graph.nodes[task.node], "question")
	if strings.trim_space(q) == "" { q = i18n.tr("Go on?") }
	Shown :: struct { app: ^App, key: u64 }
	key := questions_ask(&app.desk.questions, run.flow.id, task.node)
	actions := []platform.Notification_Action{{QUESTION_YES, i18n.tr("Yes")}, {QUESTION_NO, i18n.tr("No")}}
	// (Critical: a server does not take it away by itself, and the run waits for the person)
	n := platform.Notification{title = q, body = i18n.tr("cliche waits for your answer."), actions = actions, urgency = .Critical}
	shown := new_clone(Shown{app, key})
	sent := platform.notify_async(app.anchor, n, proc(user: rawptr, id: platform.Notification_Id, ok: bool) {
		s := (^Shown)(user)
		defer free(s)
		workflow_question_shown(s.app, s.key, id, ok)
	}, shown)
	if !sent {
		// (no notification server: its `done` may have run, or not; the question fails once)
		workflow_question_shown(app, key, 0, false)
	}
}

// The system showed a question, or could not: then its node fails, and what hangs on it is skipped.
@(private = "file")
workflow_question_shown :: proc(app: ^App, key: u64, id: platform.Notification_Id, ok: bool) {
	dropped, failed := questions_shown(&app.desk.questions, key, id, ok)
	if !failed { return }
	run := workflow_run_find(app, dropped.run)
	if run == nil { return }
	if flowgraph.run_finish(&run.flow, dropped.node, {outcome = .Failed, message = i18n.tr("the question cannot be shown: no notification")}) { workflow_pump(app, run) }
}

////////////////////////////////
// The anchor's events for the runs

// An event of the anchor the runs take: a clipboard's answer, a question's answer, a click on the last run's
// notification (its address or file opened). False: not theirs (a click then shows the history).
workflow_anchor_event :: proc(app: ^App, e: platform.Event) -> bool {
	d := &app.desk
	#partial switch e.kind {
	case .Clipboard_Data:
		if d.clip_id == 0 || e.clipboard.id != d.clip_id { return false }
		workflow_clipboard_answer(app, e.clipboard)
		return true
	case .Notification_Click, .Notification_Action, .Notification_Closed:
		asked, answer := questions_event(&d.questions, e.kind, e.notification)
		if answer != .None {
			if run := workflow_run_find(app, asked.run); run != nil {
				if answer == .Yes {
					flowgraph.run_finish(&run.flow, asked.node, {})
				} else {
					flowgraph.run_cancel(&run.flow, asked.node, i18n.tr("answered No"))
				}
				workflow_pump(app, run)
			}
			return true
		}
		if e.kind == .Notification_Click && d.notice_open != "" {
			ui.open(d.notice_open, d.notice_url ? .Url : .Path)
			return true
		}
	}
	return false
}

// Something else is said now: a click on it opens nothing of a run (app_announce calls it).
workflow_notice_forget :: proc(app: ^App) {
	delete(app.desk.notice_open)
	app.desk.notice_open, app.desk.notice_url = "", false
}

////////////////////////////////
// Runs from the clipboard and from files

// `cliche --upload-clipboard`: what the clipboard holds (a picture, else files, else a text) runs the workflow of the
// Clipboard trigger. It is read without waiting: the answer is an event of the anchor.
workflow_from_clipboard :: proc(app: ^App) {
	d := &app.desk
	if d.clip_id != 0 { return }   // (one read at a time: a second press while the first is read means the same)
	wf := workflows_for(&app.workflows, .Clipboard)
	if wf == nil { workflow_no_workflow(app); return }
	d.clip_workflow = wf.id
	d.clip_formats, d.clip_tried = platform.clipboard_formats(), {}
	workflow_clipboard_ask(app)
}

// The next format the clipboard may hold asked for; none left: said.
@(private = "file")
workflow_clipboard_ask :: proc(app: ^App) {
	d := &app.desk
	for {
		f, ok := clipboard_next(d.clip_formats, d.clip_tried)
		if !ok {
			d.clip_id = 0
			app_announce(app, .Warn, i18n.tr("Nothing to upload"), i18n.tr("The clipboard holds no picture, no file and no text."))
			return
		}
		d.clip_tried += {f}
		d.clip_id = platform.clipboard_request(app.anchor, f)
		if d.clip_id != 0 { return }
	}
}

// The clipboard's answer: what it held goes to the worker (a picture is decoded there), or the next format is asked.
@(private = "file")
workflow_clipboard_answer :: proc(app: ^App, r: platform.Clipboard_Reply) {
	d := &app.desk
	d.clip_id = 0
	empty := !r.ok
	#partial switch r.format {
	case .Text:  empty ||= strings.trim_space(r.text) == ""
	case .Files: empty ||= len(r.files) == 0
	case .Image: empty ||= len(r.data) == 0
	}
	if empty { workflow_clipboard_ask(app); return }
	// (the reply's strings live until the next poll: the job's are copies)
	j := Job_Run_Input{workflow = d.clip_workflow, origin = .Clipboard}
	#partial switch r.format {
	case .Image:
		j.image = clone_bytes(r.data)
		j.mime = strings.clone(r.mime)
	case .Files:
		j.paths = make([]string, len(r.files))
		for p, i in r.files { j.paths[i] = strings.clone(p) }
	case .Text:
		j.text = strings.clone(r.text)
	}
	worker_send(&app.worker, j)
}

// `cliche --upload-file`: the system's dialog for files, on a chore (it waits for the person); each file chosen runs
// the workflow of the Upload a file trigger (workflow_files_take, once a turn).
workflow_from_files :: proc(app: ^App) {
	d := &app.desk
	if workflows_for(&app.workflows, .Upload_File) == nil { workflow_no_workflow(app); return }
	if d.files == nil {
		d.files = new(Files_Box)
		d.files^ = {refs = 1, app = app}
	}
	box := d.files
	sync.mutex_lock(&box.lock)
	busy := box.choosing
	box.choosing = true
	sync.mutex_unlock(&box.lock)
	if busy { return }   // (one dialog at a time)
	Pick :: struct { box: ^Files_Box, title: string }
	pick := new(Pick)
	pick^ = {box, strings.clone(i18n.tr("Files to upload"))}
	sync.atomic_add(&box.refs, 1)
	work :: proc(user: rawptr) {
		pick := (^Pick)(user)
		box := pick.box
		r := platform.open_file_dialog({title = pick.title, multiple = true, remember_id = "cliche-upload"})
		sync.mutex_lock(&box.lock)
		box.choosing = false
		if !box.closed {
			if r.status == .Chosen { for p in r.paths { append(&box.chosen, strings.clone(p)) } }
			app_wake(box.app)
		}
		sync.mutex_unlock(&box.lock)
		platform.dialog_result_destroy(&r)
		delete(pick.title)
		free(pick)
		files_box_release(box)
	}
	if !tasks.add(ui.chores(), work, pick) {
		delete(pick.title)
		free(pick)
		sync.mutex_lock(&box.lock)
		box.choosing = false
		sync.mutex_unlock(&box.lock)
		files_box_release(box)
	}
}

// Once a turn: the files the dialog gave, to the worker (each is looked at there, then runs the workflow).
workflow_files_take :: proc(app: ^App) {
	box := app.desk.files
	if box == nil { return }
	sync.mutex_lock(&box.lock)
	if len(box.chosen) == 0 {
		sync.mutex_unlock(&box.lock)
		return
	}
	paths := make([]string, len(box.chosen))
	copy(paths, box.chosen[:])   // (the strings move to the job)
	clear(&box.chosen)
	sync.mutex_unlock(&box.lock)
	wf := workflows_for(&app.workflows, .Upload_File)
	if wf == nil {
		for p in paths { delete(p) }
		delete(paths)
		workflow_no_workflow(app)
		return
	}
	worker_send(&app.worker, Job_Run_Input{workflow = wf.id, origin = .File, paths = paths})
}

// The values made on the worker: a run of the workflow for each (gone meanwhile: freed), or why there are none.
workflow_run_input_result :: proc(app: ^App, r: Result_Run_Input) {
	r := r
	defer result_run_input_free(&r)
	if r.problem != "" {
		app_announce(app, .Bad, i18n.tr("Nothing to upload"), r.problem)
		return
	}
	wf := workflows_find(&app.workflows, r.workflow)
	if wf == nil { return }
	for &v in r.values {
		workflow_run_start_value(app, wf, v, {origin = r.origin})
		v = {}   // (the run's now)
	}
}

// Pin node: the picture pinned over the other windows (pin.odin, the editor's Pin too), a copy of its own: the run's
// picture may feed other branches meanwhile. False: no window can show it yet (pin_open needs the renderer's window).
@(private = "file")
workflow_pin :: proc(app: ^App, shot: Shot) -> bool {
	if app.shared.main == nil { return false }
	own := shot
	own.rgba = clone_bytes(shot.rgba)
	pin_open(app, own)
	return true
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
