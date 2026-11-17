package cliche

// The ruler: the overlay (overlay.odin) shows the frozen desktop with its magnifier, and a drag draws a line with its
// length in pixels and its angle, said beside the line. A new drag replaces the line; Shift holds it to a multiple of
// 45°. Escape (or a right click, or a close) ends it, and nothing is captured or copied: the flow goes back to Idle by
// Flow_Cancelled, its only way out. What is here is pure, tested without a window (ruler_test.odin).
//
// The points are the desktop's logical pixels, as the region's size label is: a length on a scaled output reads as the
// region overlay would frame it, not in the picture's physical pixels.

import "core:fmt"
import "core:math"

Ruler :: struct {
	from, to: Point,   // logical, on the desktop
	has_line: bool,    // a line was drawn (it stays after the release)
	dragging: bool,
}

ruler_press :: proc(r: ^Ruler, p: Point) {
	r.from, r.to, r.has_line, r.dragging = p, p, true, true
}

// The pointer moved: the line's end follows while it is dragged (`straight`: Shift, a multiple of 45°).
ruler_move :: proc(r: ^Ruler, p: Point, straight: bool) {
	if !r.dragging { return }
	r.to = straight ? ruler_snap(r.from, p) : p
}

ruler_release :: proc(r: ^Ruler, p: Point, straight: bool) {
	if !r.dragging { return }
	ruler_move(r, p, straight)
	r.dragging = false
}

// `to` moved onto the nearest line from `from` at a multiple of 45°, its length along that line kept.
ruler_snap :: proc(from, to: Point) -> Point {
	dx, dy := f64(to.x - from.x), f64(to.y - from.y)
	if dx == 0 && dy == 0 { return to }
	step := math.PI / 4
	a := math.round(math.atan2(dy, dx) / step) * step
	length := math.sqrt(dx * dx + dy * dy)
	return from + {i32(math.round(math.cos(a) * length)), i32(math.round(math.sin(a) * length))}
}

// The length of the line from `from` to `to`, in logical pixels, and its angle in degrees, in (-180, 180]: 0 to the
// right, 90 up, as a protractor reads it (the screen's y goes down).
ruler_measure :: proc(from, to: Point) -> (length, degrees: f64) {
	dx, dy := f64(to.x - from.x), f64(to.y - from.y)
	length = math.sqrt(dx * dx + dy * dy)
	if length == 0 { return 0, 0 }
	degrees = math.atan2(-dy, dx) * 180 / math.PI
	if degrees <= -180 { degrees += 360 }
	return
}

// The words said beside the line: "125.3 px  36.9°  (100 × 75)". Temp allocator.
ruler_label :: proc(from, to: Point) -> string {
	length, degrees := ruler_measure(from, to)
	// (-0.0 is said 0.0: a line drawn leftwards and back does not read "-0.0°")
	if math.abs(degrees) < 0.05 { degrees = 0 }
	return fmt.tprintf("%.1f px  %.1f°  (%d × %d)", length, degrees, abs(to.x - from.x), abs(to.y - from.y))
}
