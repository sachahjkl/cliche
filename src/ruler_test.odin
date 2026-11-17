package cliche

import "core:math"
import "core:testing"

// The angle reads as a protractor: 0 to the right, 90 up (the screen's y goes down), 180 to the left, negative below.
@(test)
a_line_is_measured :: proc(t: ^testing.T) {
	near :: proc(a, b: f64) -> bool { return math.abs(a - b) < 0.01 }
	length, degrees := ruler_measure({0, 0}, {3, 4})
	testing.expectf(t, near(length, 5) && near(degrees, -53.13), "down and right: %v, %v", length, degrees)
	_, degrees = ruler_measure({0, 0}, {10, 0})
	testing.expect(t, near(degrees, 0))
	_, degrees = ruler_measure({0, 0}, {0, -10})
	testing.expect(t, near(degrees, 90))
	_, degrees = ruler_measure({0, 0}, {-10, 0})
	testing.expectf(t, near(degrees, 180), "to the left is 180, not -180: %v", degrees)
	length, degrees = ruler_measure({7, 7}, {7, 7})
	testing.expect(t, length == 0 && degrees == 0, "a click is no line")
	testing.expect_value(t, ruler_label({0, 0}, {3, 4}), "5.0 px  -53.1°  (3 × 4)")
	testing.expect_value(t, ruler_label({10, 10}, {0, 10}), "10.0 px  180.0°  (10 × 0)")
	testing.expect_value(t, ruler_label({0, 0}, {0, 0}), "0.0 px  0.0°  (0 × 0)")
}

// Shift holds the line to the nearest multiple of 45°, its length kept.
@(test)
a_line_is_held_to_45_degrees :: proc(t: ^testing.T) {
	testing.expect_value(t, ruler_snap({0, 0}, {10, 1}), Point{10, 0})
	testing.expect_value(t, ruler_snap({0, 0}, {10, 9}), Point{10, 10})
	testing.expect_value(t, ruler_snap({5, 5}, {6, 25}), Point{5, 25})
	testing.expect_value(t, ruler_snap({3, 3}, {3, 3}), Point{3, 3})
}

// A press starts a line, the pointer drags its end, the release keeps it; a move after the release changes nothing; a
// new press replaces it.
@(test)
the_ruler_follows_a_drag :: proc(t: ^testing.T) {
	r: Ruler
	ruler_move(&r, {1, 1}, false)
	testing.expect(t, !r.has_line, "a move with no press draws nothing")
	ruler_press(&r, {5, 5})
	testing.expect(t, r.has_line && r.dragging)
	ruler_move(&r, {8, 9}, false)
	testing.expect_value(t, r.to, Point{8, 9})
	ruler_release(&r, {20, 6}, straight = true)
	testing.expect(t, r.has_line && !r.dragging)
	testing.expect_value(t, r.to, Point{20, 5})
	ruler_move(&r, {50, 50}, false)
	testing.expect_value(t, r.to, Point{20, 5})
	ruler_press(&r, {0, 0})
	testing.expect(t, r.from == Point{0, 0} && r.to == Point{0, 0}, "a new press replaces the line")
}
