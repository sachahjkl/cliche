package cliche

// Auto capture: a capture every N seconds (capture.auto_interval) of what capture.auto_source says, started and stopped
// from the tray's check item, the palette or `cliche --auto-capture`. A thread waits the interval, then puts that
// capture's command in the app's inbox, where a second start's commands go. The capture itself stays the interface
// thread's, as any other: a tick while a capture is under way is refused as a second press is (one capture at a time).
// The loop needs no timeout: the post wakes it.
//
// The interface thread never waits for the thread (src/md/features/auto-capture.md). Each run is its own heap struct,
// shared by the thread and the owner with a count of two: whichever lets go last frees it. A stop signals the run and
// lets it go; the thread ends by itself when it wakes (self cleanup). Each run has a generation: a tick of a run that is
// no longer the current one is dropped when it posts, and again when the inbox reads it (it may have been queued just
// before the stop).
//
// The ticks keep to their schedule (due += interval), so a slow post does not make them drift; a tick missed by more
// than an interval is dropped, not caught up in a burst.

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import i18n "gt:i18n"

// What an auto capture may take: the captures with no overlay. A last region with none chosen yet opens the region's
// overlay once (source_resolve), then each tick takes that rectangle.
AUTO_CAPTURE_SOURCES :: bit_set[Source]{.Screen, .Window, .All_Screens, .Last_Region}

// Where a tick goes: `generation` is its run's (auto_capture_current tells whether it still counts).
Auto_Post :: proc(user: rawptr, verb: Verb, generation: u64)

// One run: the thread's and the owner's (`refs`), on the heap allocator (the thread frees it with its own context).
Auto_Run :: struct {
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	stopping:   bool,            // guarded by `mutex`
	refs:       int,             // atomic: 2 at the start; the one that takes it to 0 frees the run
	interval:   time.Duration,
	verb:       Verb,
	generation: u64,
	post:       Auto_Post,
	user:       rawptr,
}

// The owner's side: the interface thread's, but `generation`, which the posts and the inbox read.
Auto_Capture :: struct {
	run:        ^Auto_Run,       // nil: stopped
	source:     Source,          // the current run's (the preferences it was started with)
	interval:   time.Duration,
	generation: u64,             // atomic: the current run's; 0 none
	last:       u64,             // the last generation given
}

auto_capture_running :: proc(a: ^Auto_Capture) -> bool { return a.run != nil }

// Whether a tick of `generation` comes from the current run (any thread).
auto_capture_current :: proc(a: ^Auto_Capture, generation: u64) -> bool {
	return generation != 0 && sync.atomic_load(&a.generation) == generation
}

// The command of a capture of `s` (one of AUTO_CAPTURE_SOURCES; another is the screen).
auto_capture_verb :: proc(s: Source) -> Verb {
	#partial switch s {
	case .Window:      return .Window
	case .All_Screens: return .All_Screens
	case .Last_Region: return .Last_Region
	}
	return .Screen
}

// Starts a run that posts the command of a capture of `source` to `post` every `interval` (the first one after an
// interval: a capture at once would take the menu or the palette that started it). A run going is stopped first, and
// not waited for. False: the thread cannot start.
auto_capture_start :: proc(a: ^Auto_Capture, source: Source, interval: time.Duration, post: Auto_Post, user: rawptr) -> bool {
	auto_capture_stop(a)
	// (the run and its thread on the heap allocator: the thread frees both on its own context, whatever the caller's)
	context.allocator = runtime.heap_allocator()
	a.last += 1
	run := new(Auto_Run)
	run^ = {refs = 2, interval = max(interval, time.Millisecond), verb = auto_capture_verb(source), generation = a.last, post = post, user = user}
	a.run, a.source, a.interval = run, source, run.interval
	sync.atomic_store(&a.generation, run.generation)
	if thread.create_and_start_with_poly_data(run, auto_capture_run, self_cleanup = true) == nil {
		sync.atomic_store(&a.generation, 0)
		a.run = nil
		free(run)
		return false
	}
	return true
}

// Stops the current run without waiting for its thread: its generation stops counting at once, the thread is woken
// and ends by itself. It may still be finishing one post: the lock below waits for that append at most, never for the
// interval or the thread's end. Once this returns, the run posts nothing more.
auto_capture_stop :: proc(a: ^Auto_Capture) {
	run := a.run
	if run == nil { return }
	a.run = nil
	sync.atomic_store(&a.generation, 0)
	sync.mutex_lock(&run.mutex)
	run.stopping = true
	sync.cond_signal(&run.cond)
	sync.mutex_unlock(&run.mutex)
	auto_run_release(run)
}

@(private = "file")
auto_run_release :: proc(run: ^Auto_Run) {
	if sync.atomic_sub(&run.refs, 1) == 1 { free(run, runtime.heap_allocator()) }
}

@(private = "file")
auto_capture_run :: proc(run: ^Auto_Run) {
	sync.mutex_lock(&run.mutex)
	due := time.tick_add(time.tick_now(), run.interval)
	for !run.stopping {
		left := time.tick_diff(time.tick_now(), due)
		if left > 0 {
			// (a wake with time left is a stop or a spurious one: the loop's test tells which)
			sync.cond_wait_with_timeout(&run.cond, &run.mutex, left)
			continue
		}
		// (posted under the run's lock: a stop takes it, so no post follows a stop, and `user` (the app) is alive while
		// the run is not stopped: the quit stops it before the app goes)
		run.post(run.user, run.verb, run.generation)
		due = time.tick_add(due, run.interval)
		if time.tick_diff(time.tick_now(), due) <= 0 { due = time.tick_add(time.tick_now(), run.interval) }
	}
	sync.mutex_unlock(&run.mutex)
	auto_run_release(run)
}

// The app's part

// The tray's item, as it was last given (app_tray_follow builds the menu again when it changes).
Tray_Auto :: struct { running: bool, seconds: int }

// A tick, on the run's thread: into the inbox, as a second start's command, with its generation (app_inbox drops it if
// the run was stopped meanwhile).
app_auto_tick :: proc(user: rawptr, verb: Verb, generation: u64) {
	app := (^App)(user)
	if !auto_capture_current(&app.auto_capture, generation) { return }
	sync.mutex_lock(&app.inbox_lock)
	append(&app.inbox, Inbox_Item{verb = verb, auto_generation = generation})
	sync.mutex_unlock(&app.inbox_lock)
	app_wake(app)
}

// Starts or stops the auto capture, and says so.
app_auto_capture_toggle :: proc(app: ^App) {
	a := &app.auto_capture
	if auto_capture_running(a) {
		auto_capture_stop(a)
		app_announce(app, .Info, i18n.tr("Auto capture stopped"))
		return
	}
	if !app_auto_capture_start(app) {
		app_announce(app, .Bad, i18n.tr("The auto capture cannot start"))
		return
	}
	what := i18n.tr(CAPTURE_SOURCE_TEXT[app.settings.auto_source])
	app_announce(app, .Good, fmt.tprintf(i18n.tr("Auto capture: %s every %d s"), what, app.settings.auto_interval_s), i18n.tr("The tray's menu stops it."))
}

@(private = "file")
app_auto_capture_start :: proc(app: ^App) -> bool {
	return auto_capture_start(&app.auto_capture, app.settings.auto_source, time.Duration(app.settings.auto_interval_s) * time.Second, app_auto_tick, app)
}

// After the preferences changed: a running auto capture takes the new interval or source at once (a new run; the old
// one ends by itself).
app_auto_capture_follow_prefs :: proc(app: ^App) {
	a := &app.auto_capture
	if !auto_capture_running(a) { return }
	if a.source == app.settings.auto_source && a.interval == time.Duration(app.settings.auto_interval_s) * time.Second { return }
	if !app_auto_capture_start(app) { app_announce(app, .Bad, i18n.tr("The auto capture cannot start")) }
}
