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
	f = step(t, f, Flow_Captured{}, Flow_Selecting{})
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

@(test)
cancel_returns_to_idle :: proc(t: ^testing.T) {
	f: Flow = Flow_Selecting{}
	f = step(t, f, Flow_Cancelled{}, Flow_Idle{})
	testing.expect(t, !flow_busy(f))
}

@(test)
busy_flow_refuses_a_trigger :: proc(t: ^testing.T) {
	busy := []Flow{Flow_Capturing{.Region}, Flow_Selecting{}, Flow_Encoding{.Screen}}
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
}
