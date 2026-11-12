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
