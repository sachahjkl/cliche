package cliche

import "core:testing"

@(private = "file")
step :: proc(t: ^testing.T, f: Flow, e: Flow_Event, want: Flow, loc := #caller_location) -> Flow {
	next, ok := flow_step(f, e)
	testing.expect(t, ok, "the transition is refused", loc = loc)
	testing.expect_value(t, next, want, loc = loc)
	return next
}

@(test)
region_goes_through_selecting :: proc(t: ^testing.T) {
	f: Flow = Flow_Idle{}
	f = step(t, f, Flow_Trigger{.Region}, Flow_Capturing{.Region})
	f = step(t, f, Flow_Captured{}, Flow_Selecting{.Region})
	f = step(t, f, Flow_Confirmed{}, Flow_Encoding{.Region})
	f = step(t, f, Flow_Saved{}, Flow_Done{.Region})
	f = step(t, f, Flow_Reset{}, Flow_Idle{})
}

@(test)
screen_skips_selecting :: proc(t: ^testing.T) {
	f: Flow = Flow_Idle{}
	f = step(t, f, Flow_Trigger{.Screen}, Flow_Capturing{.Screen})
	f = step(t, f, Flow_Captured{}, Flow_Encoding{.Screen})
	f = step(t, f, Flow_Save_Failed{.Not_Saved}, Flow_Failed{.Screen, .Not_Saved})
	// (a new trigger after an outcome starts again at once)
	f = step(t, f, Flow_Trigger{.Window}, Flow_Capturing{.Window})
	f = step(t, f, Flow_Capture_Failed{.Denied}, Flow_Failed{.Window, .Denied})
}

// All the screens and the last region are taken with no overlay: straight to their picture.
@(test)
all_screens_and_the_last_region_skip_selecting :: proc(t: ^testing.T) {
	for source in ([]Source{.All_Screens, .Last_Region}) {
		f: Flow = Flow_Idle{}
		f = step(t, f, Flow_Trigger{source}, Flow_Capturing{source})
		f = step(t, f, Flow_Captured{}, Flow_Encoding{source})
		f = step(t, f, Flow_Handed{}, Flow_Idle{})
	}
}

// A last region asked before any region was chosen is a region chosen now.
@(test)
a_last_region_with_none_is_a_region :: proc(t: ^testing.T) {
	testing.expect_value(t, source_resolve(.Last_Region, false), Source.Region)
	testing.expect_value(t, source_resolve(.Last_Region, true), Source.Last_Region)
	testing.expect_value(t, source_resolve(.Screen, false), Source.Screen)
}

// The colour picker chooses on the frozen desktop, then ends with no picture: a pick, never a confirm.
@(test)
a_colour_is_picked_on_the_frozen_desktop :: proc(t: ^testing.T) {
	f: Flow = Flow_Idle{}
	f = step(t, f, Flow_Trigger{.Color}, Flow_Capturing{.Color})
	f = step(t, f, Flow_Captured{}, Flow_Selecting{.Color})
	testing.expect(t, flow_busy(f))
	_, ok := flow_step(f, Flow_Confirmed{})
	testing.expect(t, !ok, "a colour is not a rectangle")
	f = step(t, f, Flow_Picked{}, Flow_Idle{})
	_, ok = flow_step(Flow_Selecting{.Region}, Flow_Picked{})
	testing.expect(t, !ok, "a region is not a colour")
	f = step(t, Flow_Selecting{.Color}, Flow_Cancelled{}, Flow_Idle{})
}

// A delay is counted down a second at a time, its notice withdrawn just before the picture; the waits make the delay.
@(test)
a_delay_is_counted_down :: proc(t: ^testing.T) {
	plan := countdown_plan(2500)
	want := []Countdown_Step{{3, 500}, {2, 1000}, {1, 1000 - COUNTDOWN_CLEAR_MS}, {0, COUNTDOWN_CLEAR_MS}}
	testing.expect_value(t, len(plan), len(want))
	total := 0
	for s, i in plan {
		if i < len(want) { testing.expect_value(t, s, want[i]) }
		total += s.wait_ms
	}
	testing.expect_value(t, total, 2500)
	short := countdown_plan(200)
	testing.expect_value(t, len(short), 2)
	if len(short) == 2 {
		testing.expect_value(t, short[0], Countdown_Step{1, 0})
		testing.expect_value(t, short[1], Countdown_Step{0, 200})
	}
	testing.expect_value(t, len(countdown_plan(0)), 0)
}

@(test)
cancel_returns_to_idle :: proc(t: ^testing.T) {
	f: Flow = Flow_Selecting{.Region}
	f = step(t, f, Flow_Cancelled{}, Flow_Idle{})
	testing.expect(t, !flow_busy(f))
	// (a delay counted down may be given up before the picture: the capture is then nothing)
	f = step(t, Flow_Capturing{.Screen}, Flow_Cancelled{}, Flow_Idle{})
}

@(test)
busy_flow_refuses_a_trigger :: proc(t: ^testing.T) {
	busy := []Flow{Flow_Capturing{.Region}, Flow_Selecting{.Region}, Flow_Selecting{.Color}, Flow_Encoding{.Screen}}
	for f in busy {
		testing.expect(t, flow_busy(f))
		next, ok := flow_step(f, Flow_Trigger{.Screen})
		testing.expect(t, !ok)
		testing.expect_value(t, next, f)
	}
}

// The picture went to the editor: the capture is over, the next one can start while the editor is open.
@(test)
a_picture_handed_to_the_editor_frees_the_flow :: proc(t: ^testing.T) {
	f: Flow = Flow_Encoding{.Region}
	f = step(t, f, Flow_Handed{}, Flow_Idle{})
	f = step(t, f, Flow_Trigger{.Screen}, Flow_Capturing{.Screen})
	_, ok := flow_step(Flow_Encoding{.Region}, Flow_Cancelled{})
	testing.expect(t, !ok)   // (an editor closed later cancels nothing)
}

@(test)
late_events_are_refused :: proc(t: ^testing.T) {
	_, ok := flow_step(Flow_Idle{}, Flow_Captured{})
	testing.expect(t, !ok)
	_, ok = flow_step(Flow_Idle{}, Flow_Reset{})
	testing.expect(t, !ok)
	_, ok = flow_step(Flow_Encoding{.Region}, Flow_Trigger{.Screen})
	testing.expect(t, !ok)
	_, ok = flow_step(Flow_Done{.Region}, Flow_Saved{})
	testing.expect(t, !ok)
	_, ok = flow_step(Flow_Idle{}, Flow_Picked{})
	testing.expect(t, !ok)
}
