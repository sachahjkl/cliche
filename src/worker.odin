package cliche

// The worker: one thread for everything that may block or that costs in proportion to the pixels. It owns the capture
// session (gt:capture's calls block: a round trip to the compositor, a portal's dialog), cuts and converts pictures,
// encodes PNG files and writes them, and writes the preferences. The interface's thread hands it jobs and takes its
// results, in order; the worker wakes the interface's loop (Worker.wake) after each result.

import "core:strings"
import "core:sync"
import "core:thread"
import capture "gt:capture"

Job_Open      :: struct {}                                    // the capture session, at start: ready before it is needed
Job_Grab      :: struct { source: Source }                    // the desktop (Region), or a shot (Screen, Window)
Job_Crop      :: struct { frame: capture.Frame, rect: Rect }   // `frame` stays the interface's: it is only read
Job_Save      :: struct { shot: Shot, folder, pattern: string, save: bool }   // owned by the job
Job_Write     :: struct { path, text: string }                // a file written whole (the preferences); owned
Job_Qr        :: struct { shot: Shot }                        // the QR code in the picture, read; owned

Job :: union { Job_Open, Job_Grab, Job_Crop, Job_Save, Job_Write, Job_Qr }

// The session is open (or why not).
Result_Opened :: struct { error: capture.Error, backend: capture.Backend }

// The desktop for a region: its picture (RGBA after the worker's swap), the outputs and the windows (owned).
Result_Desktop :: struct {
	error:      capture.Error,
	frame:      capture.Frame,
	outputs:    []capture.Output,
	windows:    []capture.Window,
	have_rects: bool,
}

// A picture to act on (owned).
Result_Shot :: struct { error: Flow_Error, shot: Shot }

// The file is written (path owned; "" when nothing was saved).
Result_Saved :: struct { error: Flow_Error, path: string }

Result_Written :: struct { ok: bool, path: string }   // (path owned)

// The text of the QR code read (owned, UTF-8).
Result_Qr :: struct { error: Flow_Error, text: string }

Result :: union { Result_Opened, Result_Desktop, Result_Shot, Result_Saved, Result_Written, Result_Qr }

Worker :: struct {
	thread:    ^thread.Thread,
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Job,      // guarded by `mutex`
	results:   [dynamic]Result,   // guarded by `mutex`
	stop:      bool,              // guarded by `mutex`
	wake:      proc(user: rawptr),
	wake_user: rawptr,
	pointer:   proc() -> (Point, bool),   // where the pointer is on the desktop, when the system says (pointer_*.odin)

	// the worker's thread only
	session:   ^capture.Session,
	session_error: capture.Error,
}

worker_start :: proc(w: ^Worker, wake: proc(user: rawptr), wake_user: rawptr) -> bool {
	w.wake, w.wake_user = wake, wake_user
	w.pointer = pointer_on_desktop
	w.thread = thread.create(worker_run)
	if w.thread == nil { return false }
	w.thread.data = w
	thread.start(w.thread)
	return true
}

// Ends the thread once the job it runs is done; the jobs left are dropped.
worker_stop :: proc(w: ^Worker) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
	for &j in w.jobs { job_free(&j) }
	delete(w.jobs)
	for &r in w.results { result_free(&r) }
	delete(w.results)
}

worker_send :: proc(w: ^Worker, j: Job) {
	sync.mutex_lock(&w.mutex)
	append(&w.jobs, j)
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
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
worker_run :: proc(t: ^thread.Thread) {
	w := (^Worker)(t.data)
	for {
		sync.mutex_lock(&w.mutex)
		for len(w.jobs) == 0 && !w.stop { sync.cond_wait(&w.cond, &w.mutex) }
		if w.stop { sync.mutex_unlock(&w.mutex); break }
		j := w.jobs[0]
		ordered_remove(&w.jobs, 0)
		sync.mutex_unlock(&w.mutex)
		worker_do(w, j)
		free_all(context.temp_allocator)
	}
	capture.close(w.session)
	w.session = nil
}

@(private = "file")
worker_do :: proc(w: ^Worker, j: Job) {
	switch v in j {
	case Job_Open:
		worker_session(w)
		worker_post(w, Result_Opened{w.session_error, w.session != nil ? w.session.backend : .None})
	case Job_Grab:
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
		worker_post(w, Result_Shot{shot = shot_of_frame(&out, .Region, bgra = false)})
	case Job_Save:
		job := v
		path, err := save_shot(&job)
		worker_post(w, Result_Saved{err, path})
	case Job_Write:
		ok := write_file(v.path, transmute([]u8)v.text)
		delete(v.text)
		worker_post(w, Result_Written{ok, v.path})
	case Job_Qr:
		shot := v.shot
		text, ok := qr_read(shot)
		shot_free(&shot)
		worker_post(w, Result_Qr{error = ok ? .None : .No_Qr, text = text})
	}
}

// The session, opened at the first need. False: none can open here (session_error says why).
@(private = "file")
worker_session :: proc(w: ^Worker) -> bool {
	if w.session != nil { return true }
	w.session, w.session_error = capture.open()
	return w.session != nil
}

job_free :: proc(j: ^Job) {
	#partial switch &v in j {
	case Job_Save:
		shot_free(&v.shot)
		delete(v.folder)
		delete(v.pattern)
	case Job_Write:
		delete(v.path)
		delete(v.text)
	case Job_Qr:
		shot_free(&v.shot)
	}
}

result_free :: proc(r: ^Result) {
	#partial switch &v in r {
	case Result_Desktop: desktop_free(&v)
	case Result_Shot:    shot_free(&v.shot)
	case Result_Saved:   delete(v.path)
	case Result_Written: delete(v.path)
	case Result_Qr:      delete(v.text)
	}
}

desktop_free :: proc(d: ^Result_Desktop) {
	capture.frame_free(&d.frame)
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
