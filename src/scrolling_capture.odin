package cliche

// The scrolling capture: one tall picture of a page that scrolls, stitched from its screens (src/md/features/
// scrolling-capture.md). The page is a rectangle chosen on the region's overlay; the wheel turns over it a step at a
// time (platform.send_wheel); after each step the worker takes the rectangle again, waits for the page to settle and
// adds the frame to gt:image's stitcher. The picture runs the region's workflow.
//
// Scroll_Run is the run's state machine, pure and tested without a desktop (scrolling_capture_test.odin). Each
// transition gives one act, which the app does where it must be done: the overlay and the wheel on the interface thread
// (X11 wants the window's own thread for the wheel), the capture and the stitch on the worker, which answers in order.
//
//   Idle -> Choosing -> Capturing <-> Wheeling
//                         \______________\____> Ending (Keep | Drop) -> Idle

import "core:math"
import "core:slice"
import "core:time"
import capture "gt:capture"
import i18n "gt:i18n"
import pic "gt:image"
import "gt:platform"

// Between two captures of a settle: about a display frame. A capture taken faster than the screen repaints only spins.
SCROLL_PACE_MS :: 16
// Before the first frame: the overlay's windows leave the screen. The overlay shows a picture of the same page, so the
// settle alone cannot tell it from the page.
SCROLL_OVERLAY_GONE_MS :: 150
// The id of Escape taken from the whole desktop while a run captures (Windows): past the shortcuts' ids (1 to their
// count, gt:shortcuts), in RegisterHotKey's range for programs (0 to 0xBFFF).
SCROLL_ESCAPE_HOTKEY :: 0xBFFF
// The scroll bar's width left out of the comparison where the system does not say it (logical pixels): the common
// toolkits draw 12 to 17, with a margin.
SCROLL_BAR_DEFAULT_PX :: 20
// Added to the system's width: a program may draw its bar wider than the system's metric, or with a border beside it.
SCROLL_BAR_MARGIN_PX  :: 4

// Why a run ended.
Scroll_End :: enum u8 {
	Done,          // the page ended, the limit came, or a frame did not join: what was gathered is kept
	Cancelled,     // Escape, the tray, the command again: nothing is kept
	Failed,        // the capture failed (`error` says why): nothing is kept
	Unavailable,   // the wheel cannot be turned here: nothing is kept
}

Scroll_Idle      :: struct {}
Scroll_Choosing  :: struct {}                                   // the region's overlay is open
Scroll_Capturing :: struct {}                                   // the worker takes a frame, settles it, stitches it
Scroll_Wheeling  :: struct {}                                   // the wheel turns (the interface thread)
Scroll_Ending    :: struct { why: Scroll_End, error: Flow_Error }   // the worker ends the stitch

Scroll_State :: union #no_nil { Scroll_Idle, Scroll_Choosing, Scroll_Capturing, Scroll_Wheeling, Scroll_Ending }

Scroll_Run :: struct {
	state:      Scroll_State,
	notches:    int,    // the step now: capture.scroll_notches, halved once by a frame that does not join
	max_frames: int,    // capture.scroll_screens
	frames:     int,    // the frames that added rows
	retried:    bool,   // the step was made smaller since the last frame added
}

Scroll_Start      :: struct { notches, max_frames: int, can_wheel: bool }   // can_wheel: send_wheel(w, 0)
Scroll_Chosen     :: struct {}                                               // the rectangle is taken
Scroll_Frame      :: struct { result: pic.Stitch_Result, error: Flow_Error }  // the worker added a frame (or failed)
Scroll_Wheeled    :: struct { ok: bool }                                     // send_wheel's answer
Scroll_Cancel     :: struct {}
Scroll_Ended      :: struct {}                                               // the worker ended the stitch

Scroll_Event :: union { Scroll_Start, Scroll_Chosen, Scroll_Frame, Scroll_Wheeled, Scroll_Cancel, Scroll_Ended }

Scroll_Act_Kind :: enum u8 {
	None,
	Unavailable,   // say that the wheel cannot be turned here
	Choose,        // open the region's overlay
	Capture,       // a frame to the worker
	Wheel,         // turn the wheel by `notches` (negative: back up)
	Keep,          // the worker ends the stitch and hands the picture back
	Drop,          // the worker ends the stitch and frees it
}

Scroll_Act :: struct { kind: Scroll_Act_Kind, notches: int }

scroll_busy :: proc(r: ^Scroll_Run) -> bool {
	_, idle := r.state.(Scroll_Idle)
	return !idle
}

// Applies `e` to `r` and gives what to do now. ok false: `e` means nothing in this state (a late cancel), and `r`
// stays.
scroll_step :: proc(r: ^Scroll_Run, e: Scroll_Event) -> (act: Scroll_Act, ok: bool) {
	switch _ in r.state {
	case Scroll_Idle:
		v, start := e.(Scroll_Start)
		if !start { break }
		if !v.can_wheel { return {kind = .Unavailable}, true }
		r^ = {state = Scroll_Choosing{}, notches = max(v.notches, 1), max_frames = max(v.max_frames, 1)}
		return {kind = .Choose}, true
	case Scroll_Choosing:
		#partial switch _ in e {
		case Scroll_Chosen:
			r.state = Scroll_Capturing{}
			return {kind = .Capture}, true
		case Scroll_Cancel:
			r.state = Scroll_Idle{}
			return {}, true
		}
	case Scroll_Capturing:
		#partial switch v in e {
		case Scroll_Frame:  return scroll_frame(r, v), true
		case Scroll_Cancel: return scroll_ending(r, .Cancelled), true
		}
	case Scroll_Wheeling:
		#partial switch v in e {
		case Scroll_Wheeled:
			if v.ok {
				r.state = Scroll_Capturing{}
				return {kind = .Capture}, true
			}
			// (refused before a second screen: the page never scrolled, so this is no scrolling capture)
			if r.frames < 2 { return scroll_ending(r, .Unavailable), true }
			return scroll_ending(r, .Done), true
		case Scroll_Cancel: return scroll_ending(r, .Cancelled), true
		}
	case Scroll_Ending:
		if _, ended := e.(Scroll_Ended); ended {
			r.state = Scroll_Idle{}
			return {}, true
		}
	}
	return {}, false
}

// What a frame added to the stitch decides.
@(private = "file")
scroll_frame :: proc(r: ^Scroll_Run, f: Scroll_Frame) -> Scroll_Act {
	if f.error != .None { return scroll_ending(r, .Failed, f.error) }
	switch f.result {
	case .Added:
		r.frames += 1
		r.retried = false
		if r.frames >= r.max_frames { return scroll_ending(r, .Done) }
		r.state = Scroll_Wheeling{}
		return {kind = .Wheel, notches = r.notches}
	case .Full:
		r.frames += 1   // (its rows up to the bound are in)
		return scroll_ending(r, .Done)
	case .Same:
		return scroll_ending(r, .Done)
	case .Refused:
		// (the rectangle changed size: an output went; with nothing gathered there is no picture)
		if r.frames == 0 { return scroll_ending(r, .Failed, .Gone) }
		return scroll_ending(r, .Done)
	case .No_Overlap:
		if r.retried || r.notches <= 1 { return scroll_ending(r, .Done) }
		// The step moved more than a screen. Back up by the difference: the page then stands a smaller step after the
		// last frame added, and the stitcher, which kept nothing of the refused frame, joins the next one to it.
		smaller := max(r.notches / 2, 1)
		back := smaller - r.notches
		r.notches, r.retried = smaller, true
		r.state = Scroll_Wheeling{}
		return {kind = .Wheel, notches = back}
	}
	return scroll_ending(r, .Done)
}

@(private = "file")
scroll_ending :: proc(r: ^Scroll_Run, why: Scroll_End, error := Flow_Error.None) -> Scroll_Act {
	r.state = Scroll_Ending{why, error}
	return {kind = why == .Done ? .Keep : .Drop}
}

// One frame of the rectangle (owned by the caller), or why not.
Scroll_Grab :: proc(user: rawptr) -> (shot: Shot, error: Flow_Error)

// A frame taken once the page settled after a step: first until a capture differs from `last` (the page moved; the
// first frame of a run skips this), then until two captures in a row are equal (it stopped). At `bound` the newest
// capture is taken: a page that never moved gives a frame equal to `last`, which the stitcher reads as its end.
scroll_settle :: proc(last: []u8, first: bool, bound: time.Duration, grab: Scroll_Grab, user: rawptr) -> (shot: Shot, error: Flow_Error) {
	deadline := time.tick_add(time.tick_now(), bound)
	moved := first
	newest: Shot
	have := false
	for {
		c, err := grab(user)
		if err != .None {
			if have { shot_free(&newest) }
			return {}, err
		}
		stable := false
		if moved {
			stable = have && slice.equal(c.rgba, newest.rgba)
		} else if !slice.equal(c.rgba, last) {
			moved = true
		}
		if have { shot_free(&newest) }
		newest, have = c, true
		if stable || time.tick_diff(time.tick_now(), deadline) <= 0 { return newest, .None }
		time.sleep(SCROLL_PACE_MS * time.Millisecond)
	}
}

// The worker's part

// A frame of the run: the rectangle (logical) taken again, settled within settle_ms, added to the worker's stitch.
// bar_px: the logical width at the right edge left out of the comparison (capture.scroll_bar_px; 0: automatic, read
// here on the worker: scroll_bar_auto_px may ask the system).
Job_Scroll_Frame :: struct { rect: Rect, settle_ms: int, bar_px: int }
// The run's end: the stitched picture handed back (`keep`), or freed.
Job_Scroll_End   :: struct { keep: bool }

Result_Scroll_Frame :: struct { result: pic.Stitch_Result, moved: int, error: Flow_Error }
Result_Scroll_Done  :: struct { shot: Shot, has_shot: bool }   // (shot owned)

// The worker's stitch of the run (the worker's thread only).
Scroll_Stitch :: struct {
	active:   bool,
	stitcher: pic.Stitcher,
	last:     []u8,   // the last frame taken: the next settle waits for the page to differ from it
	scale:    f32,
}

// The frame's columns left out of the comparison for `logical` pixels at the frame's `scale` (rounded up: a column
// half covered by the scroll bar still changes with its thumb).
scroll_ignore_columns :: proc(logical: int, scale: f32) -> int {
	if logical <= 0 { return 0 }
	s := scale > 0 ? scale : 1
	return int(math.ceil(f32(logical) * s))
}

// A frame: the first one begins the stitch, once its scale says how many columns the scroll bar takes. The session's
// pointer is off (a pointer stays where the page moves).
scroll_frame_work :: proc(st: ^Scroll_Stitch, s: ^capture.Session, job: Job_Scroll_Frame) -> Result_Scroll_Frame {
	first := !st.active
	if first { time.sleep(SCROLL_OVERLAY_GONE_MS * time.Millisecond) }
	Grab :: struct { s: ^capture.Session, rect: Rect }
	g := Grab{s, job.rect}
	grab :: proc(user: rawptr) -> (shot: Shot, error: Flow_Error) {
		g := (^Grab)(user)
		r := grab_rect(g.s, g.rect)
		return r.shot, r.error
	}
	capture.set_cursor(s, false)
	shot, err := scroll_settle(st.last, first, time.Duration(job.settle_ms) * time.Millisecond, grab, &g)
	if err != .None { return {error = err} }
	if first {
		bar := job.bar_px > 0 ? job.bar_px : scroll_bar_auto_px()
		st.stitcher = pic.stitch_begin({ignore_right = scroll_ignore_columns(bar, shot.scale)})
		st.active = true
	}
	moved, result := pic.stitch_add(&st.stitcher, {pixels = shot.rgba, width = shot.size.x, height = shot.size.y})
	delete(st.last)
	st.last, st.scale = shot.rgba, shot.scale
	return {result = result, moved = moved}
}

// The end: the picture (keep), else nothing; the stitch is freed either way.
scroll_end_work :: proc(st: ^Scroll_Stitch, keep: bool) -> Result_Scroll_Done {
	defer scroll_stitch_free(st)
	if !st.active { return {} }
	img, ok := pic.stitch_end(&st.stitcher)
	st.active = false   // (stitch_end freed the stitch: the deferred free must not end it again)
	if !ok { return {} }
	if !keep {
		pic.destroy(&img)
		return {}
	}
	return {shot = {rgba = img.pixels, size = {img.width, img.height}, source = .Region, scale = st.scale}, has_shot = true}
}

// What the stitch holds, freed (also at the worker's end: a run still going at quit).
scroll_stitch_free :: proc(st: ^Scroll_Stitch) {
	if st.active {
		img, ok := pic.stitch_end(&st.stitcher)
		if ok { pic.destroy(&img) }
	}
	delete(st.last)
	st^ = {}
}

// The app's part

@(private = "file")
SCROLL_UNAVAILABLE_TEXT := i18n.later("This desktop lets no program turn the wheel of another program's window. Capture a region instead.")

// The tray, the palette, `cliche --scrolling-capture`: starts a run, or cancels the one going.
app_scroll_toggle :: proc(app: ^App) {
	if scroll_busy(&app.scroll) {
		app_scroll_cancel(app)
		return
	}
	// (0 notches turns nothing: the answer says whether the wheel can be turned here)
	can := platform.send_wheel(app.anchor, 0)
	app.scroll_wheel_known, app.scroll_wheel_ok = true, can
	s := &app.settings
	act, _ := scroll_step(&app.scroll, Scroll_Start{notches = s.scroll_notches, max_frames = s.scroll_screens, can_wheel = can})
	if act.kind == .Unavailable {
		app_announce(app, .Bad, i18n.tr("No scrolling capture"), i18n.tr(SCROLL_UNAVAILABLE_TEXT))
		return
	}
	if !app_capture_start(app, .Region, {trigger = .Region}, .Scroll) {
		// (another capture is being taken: refused, as a second press is)
		scroll_step(&app.scroll, Scroll_Cancel{})
	}
}

// Escape, the tray, the command again. While the rectangle is chosen, the overlay's own cancel.
app_scroll_cancel :: proc(app: ^App) {
	if _, choosing := app.scroll.state.(Scroll_Choosing); choosing {
		app_region_cancelled(app)
		return
	}
	if act, ok := scroll_step(&app.scroll, Scroll_Cancel{}); ok { app_scroll_act(app, act) }
}

// The rectangle chosen on the overlay (hidden already): the pointer goes over it, Escape is taken, the first frame.
app_scroll_chosen :: proc(app: ^App, r: Rect) {
	app.scroll_rect = r
	placed := pointer_place({r.x + r.w / 2, r.y + r.h / 2})
	app.scroll_escape = platform.hotkey_register(app.anchor, SCROLL_ESCAPE_HOTKEY, {key = .Escape})
	if !placed {
		// (the toolkit moves no pointer, and cliche can only on Windows: the person holds it there)
		stop := app.scroll_escape ? i18n.tr("Escape or Cliche's icon stops it.") : i18n.tr("Cliche's icon stops it.")
		app_announce(app, .Info, i18n.tr("Keep the pointer over the page"), stop)
	}
	if act, ok := scroll_step(&app.scroll, Scroll_Chosen{}); ok { app_scroll_act(app, act) }
}

// The region's choice ended with no rectangle (cancelled, or the desktop could not be read).
app_scroll_unchosen :: proc(app: ^App) {
	scroll_step(&app.scroll, Scroll_Cancel{})
}

// Does what a transition asked. A wheel turned is answered at once: its answer is the next event.
app_scroll_act :: proc(app: ^App, act: Scroll_Act) {
	act := act
	for {
		switch act.kind {
		case .None, .Unavailable, .Choose:
			return
		case .Capture:
			worker_send(&app.worker, Job_Scroll_Frame{rect = app.scroll_rect, settle_ms = app.settings.scroll_settle_ms, bar_px = app.settings.scroll_bar_px})
			return
		case .Wheel:
			ok := platform.send_wheel(app.anchor, act.notches)
			next, stepped := scroll_step(&app.scroll, Scroll_Wheeled{ok})
			if !stepped { return }
			act = next
		case .Keep, .Drop:
			app_scroll_escape_release(app)
			worker_send(&app.worker, Job_Scroll_End{keep = act.kind == .Keep})
			return
		}
	}
}

@(private = "file")
app_scroll_escape_release :: proc(app: ^App) {
	if app.scroll_escape { platform.hotkey_unregister(app.anchor, SCROLL_ESCAPE_HOTKEY) }
	app.scroll_escape = false
}

// A frame from the worker.
app_scroll_frame :: proc(app: ^App, r: Result_Scroll_Frame) {
	if act, ok := scroll_step(&app.scroll, Scroll_Frame{r.result, r.error}); ok { app_scroll_act(app, act) }
}

// The worker ended the stitch: the picture to the region's workflow, or what went wrong said.
app_scroll_done :: proc(app: ^App, r: Result_Scroll_Done) {
	r := r
	ending, is_ending := app.scroll.state.(Scroll_Ending)
	if !is_ending {
		shot_free(&r.shot)
		return
	}
	scroll_step(&app.scroll, Scroll_Ended{})
	switch ending.why {
	case .Done:
		if !r.has_shot {
			app_announce(app, .Bad, i18n.tr("No scrolling capture"), i18n.tr(FLOW_ERROR_TEXT[.Empty]))
			return
		}
		if !workflow_capture(app, {trigger = .Region}, r.shot) {
			app_announce(app, .Bad, i18n.tr("No scrolling capture"), i18n.tr(FLOW_ERROR_TEXT[.No_Workflow]))
		}
		return
	case .Cancelled:
		app_announce(app, .Info, i18n.tr("Scrolling capture cancelled"))
	case .Failed:
		app_announce(app, .Bad, i18n.tr("No scrolling capture"), i18n.tr(FLOW_ERROR_TEXT[ending.error]))
	case .Unavailable:
		app_announce(app, .Bad, i18n.tr("No scrolling capture"), i18n.tr(SCROLL_UNAVAILABLE_TEXT))
	}
	shot_free(&r.shot)
}

// What the settings say under the scrolling capture's step, once a start found the wheel out of reach.
scroll_settings_problem :: proc(app: ^App) -> string {
	if app.scroll_wheel_known && !app.scroll_wheel_ok { return i18n.tr(SCROLL_UNAVAILABLE_TEXT) }
	return ""
}
