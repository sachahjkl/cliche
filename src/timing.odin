package cliche

// With CLICHE_TIMING set in the environment, how long each step from a trigger took, on standard error: the latency
// from a shortcut to the editor, measured where it is spent. Read once at start; nothing is printed without it.

import "core:fmt"
import "core:os"
import "core:time"

@(private = "file") timing_on: bool
@(private = "file") timing_from: time.Tick
@(private = "file") timing_last: time.Tick

timing_init :: proc() { timing_on = os.get_env("CLICHE_TIMING", context.temp_allocator) != "" }

// A trigger: the clock starts.
timing_start :: proc(what: string) {
	if !timing_on { return }
	timing_from = time.tick_now()
	timing_last = timing_from
	fmt.eprintfln("timing: %s", what)
}

// A step done: its time, and the time since the trigger.
timing_mark :: proc(what: string) {
	if !timing_on || timing_from == {} { return }
	now := time.tick_now()
	fmt.eprintfln("timing: %-28s +%6.1f ms  (%6.1f ms)", what, time.duration_milliseconds(time.tick_diff(timing_last, now)), time.duration_milliseconds(time.tick_diff(timing_from, now)))
	timing_last = now
}

// A step of another thread (the worker's): the time since the trigger only (the steps' own clock is the interface's).
timing_note :: proc(what: string) {
	if !timing_on || timing_from == {} { return }
	fmt.eprintfln("timing:   (worker) %-19s          (%6.1f ms)", what, time.duration_milliseconds(time.tick_since(timing_from)))
}
