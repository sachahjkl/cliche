package cliche

import "core:testing"
import capture "gt:capture"

OUT :: Rect{0, 0, 1920, 1080}

@(test)
drag_makes_a_rectangle :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_press(&s, {100, 200})
	selection_move(&s, {50, 150})   // (up and left: the rectangle is normalized)
	testing.expect_value(t, selection_release(&s, {40, 120}), Release.Rect)
	testing.expect_value(t, s.rect, Rect{40, 120, 60, 80})
	testing.expect(t, s.has_rect)
}

@(test)
small_move_is_a_click :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_press(&s, {10, 10})
	selection_move(&s, {11, 12})
	testing.expect_value(t, selection_release(&s, {12, 11}), Release.Click)
	testing.expect(t, !s.has_rect)
	testing.expect_value(t, selection_release(&s, {12, 11}), Release.None)
}

@(test)
drag_stays_inside_the_output :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, {1920, 0, 1280, 1024})
	selection_press(&s, {1000, -50})   // (left of the output and above it)
	selection_release(&s, {5000, 5000})
	testing.expect_value(t, s.rect, Rect{1920, 0, 1280, 1024})
}

@(test)
nudge_and_resize_stop_at_the_edges :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_set(&s, {1900, 1000, 10, 10})
	selection_nudge(&s, {50, 100})
	testing.expect_value(t, s.rect, Rect{1910, 1070, 10, 10})
	selection_nudge(&s, {-5000, 0})
	testing.expect_value(t, s.rect.x, 0)
	selection_resize(&s, {-100, 0})
	testing.expect_value(t, s.rect.w, 1)
	selection_resize(&s, {5000, 5000})
	testing.expect_value(t, s.rect, Rect{0, 1070, 1920, 10})
}

@(test)
nothing_moves_without_a_rectangle :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_nudge(&s, {5, 5})
	selection_resize(&s, {5, 5})
	testing.expect(t, !s.has_rect)
	testing.expect_value(t, s.rect, Rect{})
}

// The grips of a rectangle: its corners and edges within GRIP_REACH, inside or out; its inside; nothing beyond.
@(test)
grips_are_found_around_the_rectangle :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	testing.expect_value(t, selection_grip_at(&s, {10, 10}), Grip.None)   // (no rectangle: no grip)
	selection_set(&s, {100, 100, 200, 100})
	testing.expect_value(t, selection_grip_at(&s, {100, 100}), Grip.NW)
	testing.expect_value(t, selection_grip_at(&s, {304, 96}), Grip.NE)
	testing.expect_value(t, selection_grip_at(&s, {97, 203}), Grip.SW)
	testing.expect_value(t, selection_grip_at(&s, {300, 200}), Grip.SE)
	testing.expect_value(t, selection_grip_at(&s, {200, 95}), Grip.N)
	testing.expect_value(t, selection_grip_at(&s, {200, 204}), Grip.S)
	testing.expect_value(t, selection_grip_at(&s, {102, 150}), Grip.W)
	testing.expect_value(t, selection_grip_at(&s, {298, 150}), Grip.E)
	testing.expect_value(t, selection_grip_at(&s, {200, 150}), Grip.Move)
	testing.expect_value(t, selection_grip_at(&s, {200, 90}), Grip.None)
	testing.expect_value(t, selection_grip_at(&s, {400, 150}), Grip.None)
	// a rectangle narrower than two reaches: the nearer edge
	selection_set(&s, {100, 100, 4, 100})
	testing.expect_value(t, selection_grip_at(&s, {101, 150}), Grip.W)
	testing.expect_value(t, selection_grip_at(&s, {104, 150}), Grip.E)
}

// A corner dragged resizes from it; past the other corner the rectangle turns over and stays normalized.
@(test)
a_corner_resizes_the_rectangle :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_set(&s, {100, 100, 200, 100})
	testing.expect_value(t, selection_take(&s, {300, 200}), Grip.SE)
	selection_move(&s, {350, 260})
	testing.expect_value(t, s.rect, Rect{100, 100, 250, 160})
	testing.expect_value(t, selection_release(&s, {350, 260}), Release.Adjusted)
	testing.expect(t, s.has_rect)
	testing.expect_value(t, s.grip, Grip.None)
	// the top-left corner past the bottom right: turned over
	selection_take(&s, {100, 100})
	selection_release(&s, {400, 300})
	testing.expect_value(t, s.rect, Rect{350, 260, 50, 40})
	// an edge onto the one in front of it: one pixel kept
	selection_set(&s, {100, 100, 200, 100})
	selection_take(&s, {300, 150})
	selection_release(&s, {100, 150})
	testing.expect_value(t, s.rect, Rect{100, 100, 1, 100})
}

// The inside moves the rectangle, its size kept, stopped at the edges of the output.
@(test)
the_inside_moves_the_rectangle :: proc(t: ^testing.T) {
	s: Selection
	selection_reset(&s, OUT)
	selection_set(&s, {100, 100, 200, 100})
	testing.expect_value(t, selection_take(&s, {200, 150}), Grip.Move)
	selection_move(&s, {250, 170})
	testing.expect_value(t, s.rect, Rect{150, 120, 200, 100})
	selection_release(&s, {5000, 5000})
	testing.expect_value(t, s.rect, Rect{1720, 980, 200, 100})
	// a grip taken and let go where it was changes nothing
	selection_take(&s, {1800, 1000})
	testing.expect_value(t, selection_release(&s, {1801, 1001}), Release.Held)
	testing.expect_value(t, s.rect, Rect{1720, 980, 200, 100})
	// far from it: no grip, a press draws a new one
	testing.expect_value(t, selection_take(&s, {10, 10}), Grip.None)
	selection_press(&s, {10, 10})
	testing.expect(t, !s.has_rect)
	testing.expect_value(t, selection_release(&s, {60, 40}), Release.Rect)
	testing.expect_value(t, s.rect, Rect{10, 10, 50, 30})
}

@(test)
two_presses_close_together_are_a_double_click :: proc(t: ^testing.T) {
	c: Click_Track
	testing.expect(t, !click_double(&c, {10, 10}, 1000))
	testing.expect(t, click_double(&c, {11, 12}, 1300))
	testing.expect(t, !click_double(&c, {11, 12}, 1350))   // (a third press starts again)
	testing.expect(t, !click_double(&c, {11, 12}, 1350 + DOUBLE_CLICK_MS + 1))   // (too late)
	testing.expect(t, !click_double(&c, {40, 12}, 1360 + DOUBLE_CLICK_MS + 1))   // (too far)
}

@(test)
frame_pick_takes_the_front_window_clamped :: proc(t: ^testing.T) {
	wins := []capture.Window{
		{id = 1, rect = {100, 100, 200, 200}, has_rect = true},
		{id = 2, rect = {-50, 0, 400, 400}, has_rect = true},
	}
	r, ok := frame_pick(wins, {150, 150}, OUT, true)
	testing.expect(t, ok)
	testing.expect_value(t, r, Rect{100, 100, 200, 200})
	r, ok = frame_pick(wins, {10, 10}, OUT, true)
	testing.expect(t, ok)
	testing.expect_value(t, r, Rect{0, 0, 350, 400})
	_, ok = frame_pick(wins, {150, 150}, OUT, false)
	testing.expect(t, !ok)
	_, ok = frame_pick(wins, {1000, 1000}, OUT, true)
	testing.expect(t, !ok)
}

@(test)
output_for_window_uses_size_then_pointer :: proc(t: ^testing.T) {
	outs := []capture.Output{
		{id = 1, rect = {0, 0, 2560, 1440}},
		{id = 2, rect = {2560, 0, 1920, 1080}},
		{id = 3, rect = {4480, 0, 1920, 1080}},
	}
	testing.expect_value(t, output_for_window(outs, {2560, 1440}, nil, nil), 0)
	testing.expect_value(t, output_for_window(outs, {1920, 1080}, nil, nil), 1)
	testing.expect_value(t, output_for_window(outs, {1920, 1080}, nil, Point{5000, 10}), 2)
	testing.expect_value(t, output_for_window(outs, {1921, 1079}, nil, nil), 1)   // (rounding of a fractional scale)
	testing.expect_value(t, output_for_window(outs, {800, 600}, nil, nil), 0)
	testing.expect_value(t, output_for_window(outs, {800, 600}, Point{3000, 10}, nil), 1)
	testing.expect_value(t, output_for_window(nil, {800, 600}, nil, nil), -1)
}
