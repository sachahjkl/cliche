package cliche

// The worker: one thread for everything that may block or that costs in proportion to the pixels. It owns the capture
// session (gt:capture's calls block: a round trip to the compositor, a portal's dialog), cuts and converts pictures,
// encodes PNG files and writes them. The interface's thread hands it jobs and takes its results, in order; the worker
// wakes the interface's loop (Worker.wake) after each result. Its thread is a gt:tasks pool of one thread that never
// grows: a capture session belongs to the thread that opened it, and each job sees the ones before it done.

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import capture "gt:capture"
import flowgraph "gt:flowgraph"
import png "gt:png"
import "gt:platform"
import setup "gt:setup"
import tasks "gt:tasks"

Job_Open      :: struct {}                                    // the capture session, at start: ready before it is needed
Job_Grab      :: struct { source: Source, delay_ms: int }     // the desktop (Region), or a shot (Screen, Window) after delay_ms
Job_Crop      :: struct { frame: capture.Frame, rect: Rect }   // `frame` stays the interface's: it is only read
Job_Save      :: struct { editor: u64, shot: Shot, folder, pattern: string }   // an editor's Ctrl+S (Editor.id); owned by the job
Job_Copy_Encode :: struct { editor: u64, shot: Shot }         // an editor's Ctrl+C (Editor.id): its PNG for the clipboard, made here (owned)
Job_Write     :: struct { path, text: string }                // a file written whole (the preferences, the workflows); owned
Job_Workflows_Load :: struct {}                               // the workflows' file, read at the start (workflow_store.odin)
Job_Picture_Load :: struct { path: string, workflow: u64 }    // a PNG of the history decoded, for a preview run of `workflow`; owned
Job_Uploaders :: struct {}                                    // the uploaders found, for the settings
Job_Import_Uploader :: struct { path: string }                // a .sxcu file chosen in the system's dialog, copied in; owned
Job_Open_Folder :: struct { folder: string }                  // the save folder in the file manager ("": the default); owned
Job_Integrate :: struct { menu, autostart: bool }             // cliche's launcher and its start with the session (integration.odin)
Job_Setup_Facts :: struct {}                                  // whether this cliche is the installed copy (updates.odin)
Job_Setup_Updated :: struct { version: string }               // an update in place: the install's manifest and record say it (owned)

Job :: union { Job_History, Job_Open, Job_Grab, Job_Crop, Job_Save, Job_Copy_Encode, Job_Write, Job_Node, Job_Thumbnail, Job_Workflows_Load, Job_Picture_Load, Job_Open_Folder, Job_Integrate, Job_Uploaders, Job_Import_Uploader, Job_Setup_Facts, Job_Setup_Updated }

// The session is open (or why not); the folder screenshots go to when save.folder is empty (owned).
Result_Opened :: struct { error: capture.Error, backend: capture.Backend, default_folder: string }

// The desktop for a region: its picture (RGBA after the worker's swap), the outputs and the windows (owned).
Result_Desktop :: struct {
	error:      capture.Error,
	frame:      capture.Frame,
	outputs:    []capture.Output,
	windows:    []capture.Window,
	have_rects: bool,
	pointer_output: u64,   // the output the pointer is on (capture.pointer), when has_pointer_output
	has_pointer_output: bool,
}

// A picture to act on (owned).
Result_Shot :: struct { error: Flow_Error, shot: Shot }

// An editor's Ctrl+C (`editor`: its Editor.id): the picture and its PNG, which the interface's thread puts on the clipboard (owned).
Result_Copy_Encoded :: struct { editor: u64, shot: Shot, png: []u8 }

// An editor's Ctrl+S is written (`editor`: its Editor.id; save.odin's Saved, its path owned).
Result_Saved :: struct { editor: u64, using saved: Saved }

// The workflows read (workflow_store.odin): the list (owned), and why the file could not be used ("" none; owned).
Result_Workflows :: struct { workflows: Workflows, problem: string }

// A picture of the history decoded for a preview run of `workflow` (owned; ok false: it cannot be read).
Result_Picture :: struct { shot: Shot, workflow: u64, ok: bool }

// The uploaders found (owned) and what was wrong with the others; `imported`: the name of one just imported.
Result_Uploaders :: struct { names: []string, problems: []string, imported: string, import_problem: string }

Result_Written :: struct { ok: bool, path: string }   // (path owned)

// What went wrong putting cliche on the desktop, or recording an update in its install (owned; "": nothing).
Result_Integrated :: struct { problem: string }

// This cliche is the installed copy (setup.facts): it updates itself (update.auto).
Result_Setup_Facts :: struct { installed: bool }

Result :: union { Result_History, Result_Opened, Result_Desktop, Result_Shot, Result_Saved, Result_Copy_Encoded, Result_Thumbnail, Result_Written, Result_Node, Result_Workflows, Result_Picture, Result_Integrated, Result_Uploaders, Result_Setup_Facts }

Worker :: struct {
	pool:      tasks.Pool,
	started:   bool,              // (an editor of clichetool shots has none: the user's preferences are not its)
	stopping:  bool,              // (atomic) the jobs that wait are handed back, not run
	mutex:     sync.Mutex,
	results:   [dynamic]Result,   // guarded by `mutex`
	left:      [dynamic]Job,      // guarded by `mutex`: the jobs not run, freed by worker_stop on the interface's thread
	wake:      proc(user: rawptr),
	wake_user: rawptr,
	pointer:   proc() -> (Point, bool),   // where the pointer is on the desktop, when the system says (pointer_*.odin)

	// the worker's thread only
	history:   History_Disk,       // the history's copy and its file (history.odin)
	fonts:     Worker_Fonts,       // a watermark's text (workflow_ops.odin)
	session:   ^capture.Session,
	session_error: capture.Error,
}

// A job handed to the pool (the heap's: the pool's thread frees it).
@(private = "file")
Worker_Item :: struct { w: ^Worker, job: Job }

worker_start :: proc(w: ^Worker, wake: proc(user: rawptr), wake_user: rawptr) {
	w.wake, w.wake_user = wake, wake_user
	w.pointer = pointer_on_desktop
	tasks.start(&w.pool, {threads = 1})
	w.started = true
}

// Ends the thread once the job it runs is done; the jobs left are dropped here, where their pictures may be let go.
worker_stop :: proc(w: ^Worker) {
	if !w.started { return }
	sync.atomic_store(&w.stopping, true)
	// (last in the queue: the session closes on the thread that opened it, after every job left is handed back)
	_ = tasks.add(&w.pool, worker_close, w)
	tasks.stop(&w.pool)
	for &j in w.left { job_free(&j) }
	delete(w.left)
	for &r in w.results { result_free(&r) }
	delete(w.results)
}

worker_send :: proc(w: ^Worker, j: Job) {
	it := new(Worker_Item)
	it^ = {w, j}
	// (a pool not started runs its work on the caller's thread: an app of clichetool shots has no worker, nothing runs)
	if !w.started || !tasks.add(&w.pool, worker_item_run, it) {
		job_free(&it.job)
		free(it)
	}
}

// The results since the last call, in order (temp allocator; what each holds is the caller's).
worker_take :: proc(w: ^Worker) -> []Result {
	sync.guard(&w.mutex)
	out := make([]Result, len(w.results), context.temp_allocator)
	copy(out, w.results[:])
	clear(&w.results)
	return out
}

@(private = "file")
worker_post :: proc(w: ^Worker, r: Result) {
	sync.mutex_lock(&w.mutex)
	append(&w.results, r)
	sync.mutex_unlock(&w.mutex)
	w.wake(w.wake_user)
}

@(private = "file")
worker_item_run :: proc(data: rawptr) {
	it := (^Worker_Item)(data)
	w := it.w
	if sync.atomic_load(&w.stopping) {
		sync.mutex_lock(&w.mutex)
		append(&w.left, it.job)
		sync.mutex_unlock(&w.mutex)
	} else {
		worker_do(w, it.job)
	}
	free(it)
}

@(private = "file")
worker_close :: proc(data: rawptr) {
	w := (^Worker)(data)
	capture.close(w.session)
	w.session = nil
	history_disk_free(&w.history)
	worker_fonts_destroy(&w.fonts)
}

@(private = "file")
worker_do :: proc(w: ^Worker, j: Job) {
	switch v in j {
	case Job_Open:
		worker_session(w)
		worker_post(w, Result_Opened{w.session_error, w.session != nil ? w.session.backend : .None, save_folder_default()})
	case Job_Grab:
		// (a screen or a window waits: a menu opened meanwhile is in the picture; the worker has nothing else to do then)
		if v.delay_ms > 0 { time.sleep(time.Duration(v.delay_ms) * time.Millisecond) }
		if !worker_session(w) {
			if v.source == .Region { worker_post(w, Result_Desktop{error = w.session_error}) } else { worker_post(w, Result_Shot{error = flow_error_of(w.session_error)}) }
			return
		}
		switch v.source {
		case .Region: worker_post(w, grab_desktop(w.session))
		case .Screen: worker_post(w, grab_screen(w.session, w.pointer))
		case .Window: worker_post(w, grab_window(w.session))
		}
	case Job_Crop:
		out, ok := capture.crop(v.frame, v.rect)
		if !ok { worker_post(w, Result_Shot{error = .Empty}); return }
		worker_post(w, Result_Shot{shot = shot_of_frame(&out, .Region)})
	case Job_Save:
		job := v
		worker_post(w, Result_Saved{editor = v.editor, saved = save_shot(&job)})
	case Job_Thumbnail:
		job := v
		worker_post(w, thumbnail_work(&job))
	case Job_Copy_Encode:
		worker_post(w, Result_Copy_Encoded{editor = v.editor, shot = v.shot, png = png.encode(v.shot.rgba, v.shot.size.x, v.shot.size.y, .Fast)})
	case Job_Write:
		ok := write_file(v.path, transmute([]u8)v.text)
		delete(v.text)
		worker_post(w, Result_Written{ok, v.path})
	case Job_Node:
		job := v
		worker_post(w, node_work(&job, &w.fonts))
	case Job_Workflows_Load:
		list, problem := workflows_load()
		worker_post(w, Result_Workflows{list, problem})
	case Job_Picture_Load:
		worker_post(w, picture_load(v.path, v.workflow))
		delete(v.path)
	case Job_Open_Folder:
		folder := v.folder != "" ? v.folder : save_folder_default(context.temp_allocator)
		_ = os.make_directory_all(folder)
		_ = platform.open_path(folder)
		delete(v.folder)
	case Job_History:
		if r, has := history_job_run(&w.history, v); has { worker_post(w, r) }
	case Job_Uploaders:
		worker_post(w, uploaders_result("", ""))
	case Job_Import_Uploader:
		name, problem := uploader_import(v.path, context.temp_allocator)
		delete(v.path)
		worker_post(w, uploaders_result(name, problem))
	case Job_Integrate:
		problem := integration_apply(v.menu, v.autostart)
		worker_post(w, Result_Integrated{problem != "" ? strings.clone(problem) : ""})
	case Job_Setup_Facts:
		worker_post(w, Result_Setup_Facts{installed = setup.facts(setup_options()).running_it})
	case Job_Setup_Updated:
		ok, why := setup.updated(setup_options(), v.version)
		delete(v.version)
		worker_post(w, Result_Integrated{ok ? "" : strings.concatenate({"the update is in place, but ", why})})
	}
}

// The session, opened at the first need. False: none can open here (session_error says why).
@(private = "file")
worker_session :: proc(w: ^Worker) -> bool {
	if w.session != nil { return true }
	w.session, w.session_error = capture.open()
	// (RGBA from the capture itself: the textures, the clipboard and the PNG encoder take it, and no pass swaps it)
	if w.session != nil { capture.set_pixel_order(w.session, .RGBA) }
	return w.session != nil
}

job_free :: proc(j: ^Job) {
	#partial switch &v in j {
	case Job_Copy_Encode:
		shot_free(&v.shot)
	case Job_Thumbnail:
		flowgraph.value_release(&v.input)
	case Job_Save:
		shot_free(&v.shot)
		delete(v.folder)
		delete(v.pattern)
	case Job_Write:
		delete(v.path)
		delete(v.text)
	case Job_Node:
		job_node_free(&v)
	case Job_Picture_Load:
		delete(v.path)
	case Job_Import_Uploader:
		delete(v.path)
	case Job_Open_Folder:
		delete(v.folder)
	case Job_History:
		history_job_free(&v)
	case Job_Setup_Updated:
		delete(v.version)
	}
}

result_free :: proc(r: ^Result) {
	#partial switch &v in r {
	case Result_Desktop: desktop_free(&v)
	case Result_Shot:    shot_free(&v.shot)
	case Result_Saved:   delete(v.path)
	case Result_Copy_Encoded: shot_free(&v.shot); delete(v.png)
	case Result_Thumbnail: delete(v.thumbnail)
	case Result_Node:    result_node_free(&v)
	case Result_Workflows: workflows_free(&v.workflows); delete(v.problem)
	case Result_Picture: shot_free(&v.shot)
	case Result_Uploaders: uploaders_result_free(&v)
	case Result_History: history_result_free(&v)
	case Result_Written: delete(v.path)
	case Result_Opened:  delete(v.default_folder)
	case Result_Integrated: delete(v.problem)
	}
}

desktop_free :: proc(d: ^Result_Desktop) {
	capture.frame_destroy(&d.frame)
	for o in d.outputs { delete(o.name) }
	delete(d.outputs)
	for wi in d.windows { delete(wi.title); delete(wi.app_id) }
	delete(d.windows)
	d^ = {}
}

// Copies of the session's lists (they are valid only until its next read).
outputs_clone :: proc(outs: []capture.Output) -> []capture.Output {
	out := make([]capture.Output, len(outs))
	for o, i in outs {
		out[i] = o
		out[i].name = strings.clone(o.name)
	}
	return out
}

windows_clone :: proc(wins: []capture.Window) -> []capture.Window {
	out := make([]capture.Window, len(wins))
	for wi, i in wins {
		out[i] = wi
		out[i].title = strings.clone(wi.title)
		out[i].app_id = strings.clone(wi.app_id)
	}
	return out
}

// The names of the uploaders found, for the settings (worker), with what an import gave.
@(private = "file")
uploaders_result :: proc(imported, import_problem: string) -> Result_Uploaders {
	list, problems := uploaders_load(context.temp_allocator)
	r := Result_Uploaders{names = make([]string, len(list)), problems = make([]string, len(problems))}
	for u, i in list { r.names[i] = strings.clone(u.name) }
	for p, i in problems { r.problems[i] = strings.clone(p) }
	r.imported = strings.clone(imported)
	r.import_problem = strings.clone(import_problem)
	return r
}

uploaders_result_free :: proc(r: ^Result_Uploaders) {
	for n in r.names { delete(n) }
	delete(r.names)
	for p in r.problems { delete(p) }
	delete(r.problems)
	delete(r.imported)
	delete(r.import_problem)
	r^ = {}
}
