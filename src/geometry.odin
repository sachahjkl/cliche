package cliche

// The geometry of a region: the rectangle the user drags, nudges and resizes on the frozen desktop, and the window
// framed under the pointer. Pure: the overlay (overlay.odin) feeds it points in desktop coordinates (logical pixels, as
// gt:capture gives them) and draws what it says. The tests drive it without a window (geometry_test.odin).

import capture "gt:capture"

Rect :: capture.Rect
Point :: [2]i32

// A press that moves less than this (logical pixels) is a click: it takes the framed window, not a rectangle.
DRAG_THRESHOLD :: 3

// How near an edge or a corner of the rectangle (logical pixels) a press takes it.
GRIP_REACH :: 6

// Two presses this close in time (and within DRAG_THRESHOLD) are a double click.
DOUBLE_CLICK_MS :: 400

// What a release of the button decided.
Release :: enum u8 {
	None,       // no drag was going on
	Click,      // the pointer did not move: a click (the framed window, when there is one)
	Rect,       // a rectangle was dragged
	Adjusted,   // the rectangle chosen was moved or resized by one of its grips
	Held,       // one of its grips was taken and let go where it was: nothing changed
}

// A part of the rectangle chosen that the pointer takes: the inside moves it, an edge or a corner resizes it.
Grip :: enum u8 { None, Move, N, S, E, W, NE, NW, SE, SW }

// The rectangle being chosen. `rect` is normalized (w, h >= 0) and always inside `bounds`.
Selection :: struct {
	bounds:   Rect,    // the desktop area the selection stays in: the output the overlay covers
	rect:     Rect,
	anchor:   Point,   // where the drag started
	dragging: bool,
	moved:    bool,    // the drag went past DRAG_THRESHOLD
	has_rect: bool,    // a rectangle is chosen (dragged, or set): the keys and the grips adjust it, Enter takes it
	grip:     Grip,    // what the drag holds: None draws a new rectangle
	start:    Rect,    // the rectangle when the grip was taken
}

rect_empty :: proc(r: Rect) -> bool { return r.w <= 0 || r.h <= 0 }

rect_contains :: proc(r: Rect, p: Point) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// The rectangle between two corners, in either order.
rect_from_points :: proc(a, b: Point) -> Rect {
	return {min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
}

// The part of `r` inside `bounds` (empty when they do not meet).
rect_clamp :: proc(r, bounds: Rect) -> Rect {
	x0, y0 := max(r.x, bounds.x), max(r.y, bounds.y)
	x1, y1 := min(r.x + r.w, bounds.x + bounds.w), min(r.y + r.h, bounds.y + bounds.h)
	if x1 <= x0 || y1 <= y0 { return {x0, y0, 0, 0} }
	return {x0, y0, x1 - x0, y1 - y0}
}

// `p` moved into `bounds`, edges included: a corner of the selection may sit on the right or bottom edge.
point_clamp :: proc(p: Point, bounds: Rect) -> Point {
	return {clamp(p.x, bounds.x, bounds.x + bounds.w), clamp(p.y, bounds.y, bounds.y + bounds.h)}
}

selection_reset :: proc(s: ^Selection, bounds: Rect) {
	s^ = {bounds = bounds}
}

// A press that draws a new rectangle (what was chosen is dropped).
selection_press :: proc(s: ^Selection, p: Point) {
	q := point_clamp(p, s.bounds)
	s.anchor = q
	s.dragging = true
	s.moved = false
	s.grip = .None
	s.has_rect = false
	s.rect = {q.x, q.y, 0, 0}
}

// A press on the rectangle chosen: its grip under `p` is taken (the drag moves or resizes it). .None: no grip there,
// nothing taken (a press there draws a new rectangle: selection_press).
selection_take :: proc(s: ^Selection, p: Point, reach: i32 = GRIP_REACH) -> Grip {
	g := selection_grip_at(s, p, reach)
	if g == .None { return .None }
	s.anchor = point_clamp(p, s.bounds)
	s.dragging = true
	s.moved = false
	s.grip = g
	s.start = s.rect
	return g
}

selection_move :: proc(s: ^Selection, p: Point) {
	if !s.dragging { return }
	q := point_clamp(p, s.bounds)
	if !s.moved {
		d := q - s.anchor
		if abs(d.x) < DRAG_THRESHOLD && abs(d.y) < DRAG_THRESHOLD { return }
		s.moved = true
	}
	if s.grip != .None {
		s.rect = rect_grip_apply(s.start, s.grip, q - s.anchor, s.bounds)
		return
	}
	s.rect = rect_from_points(s.anchor, q)
	s.has_rect = !rect_empty(s.rect)
}

selection_release :: proc(s: ^Selection, p: Point) -> Release {
	if !s.dragging { return .None }
	selection_move(s, p)
	s.dragging = false
	held := s.grip != .None
	s.grip = .None
	if held { return s.moved ? .Adjusted : .Held }
	if !s.moved { return .Click }
	return s.has_rect ? .Rect : .Click
}

// The grip of the rectangle chosen under `p`: a corner, an edge (within `reach` of it, inside or out), the inside;
// .None elsewhere, or with no rectangle. On a rectangle narrower than two reaches, the nearer edge wins.
selection_grip_at :: proc(s: ^Selection, p: Point, reach: i32 = GRIP_REACH) -> Grip {
	if !s.has_rect { return .None }
	r := s.rect
	x0, y0, x1, y1 := r.x, r.y, r.x + r.w, r.y + r.h
	if p.x < x0 - reach || p.x > x1 + reach || p.y < y0 - reach || p.y > y1 + reach { return .None }
	side :: proc(v, lo, hi, reach: i32) -> i32 {
		near_lo, near_hi := abs(v - lo) <= reach, abs(v - hi) <= reach
		switch {
		case near_lo && near_hi: return abs(v - lo) <= abs(v - hi) ? -1 : 1
		case near_lo:            return -1
		case near_hi:            return 1
		}
		return 0
	}
	h, v := side(p.x, x0, x1, reach), side(p.y, y0, y1, reach)
	switch {
	case h < 0 && v < 0: return .NW
	case h > 0 && v < 0: return .NE
	case h < 0 && v > 0: return .SW
	case h > 0 && v > 0: return .SE
	case v < 0:          return .N
	case v > 0:          return .S
	case h < 0:          return .W
	case h > 0:          return .E
	}
	return rect_contains(r, p) ? .Move : .None
}

// `start` with its grip `g` moved by `d`, inside `bounds`. Move keeps the size and stops at the edges; an edge dragged
// past the one in front of it turns the rectangle over (it stays normalized), never less than a pixel wide.
rect_grip_apply :: proc(start: Rect, g: Grip, d: Point, bounds: Rect) -> Rect {
	if g == .Move {
		r := start
		r.x = clamp(r.x + d.x, bounds.x, bounds.x + bounds.w - r.w)
		r.y = clamp(r.y + d.y, bounds.y, bounds.y + bounds.h - r.h)
		return r
	}
	a := Point{start.x, start.y}
	b := Point{start.x + start.w, start.y + start.h}
	switch g {
	case .N:  a.y += d.y
	case .S:  b.y += d.y
	case .W:  a.x += d.x
	case .E:  b.x += d.x
	case .NW: a += d
	case .SE: b += d
	case .NE: a.y += d.y; b.x += d.x
	case .SW: a.x += d.x; b.y += d.y
	case .None, .Move:
	}
	r := rect_from_points(point_clamp(a, bounds), point_clamp(b, bounds))
	// (an edge on the other: one pixel kept, inside the bounds)
	if r.w == 0 { r.w = 1; r.x = min(r.x, bounds.x + bounds.w - 1) }
	if r.h == 0 { r.h = 1; r.y = min(r.y, bounds.y + bounds.h - 1) }
	return r
}

// The presses of a button, for a double click.
Click_Track :: struct {
	at:  Point,
	ms:  f64,
	has: bool,
}

// Whether a press at `p` at `ms` (milliseconds) makes a double click with the press before; a double click is then
// forgotten (a third press starts again).
click_double :: proc(c: ^Click_Track, p: Point, ms: f64) -> bool {
	double := c.has && ms - c.ms <= DOUBLE_CLICK_MS && abs(p.x - c.at.x) <= DRAG_THRESHOLD && abs(p.y - c.at.y) <= DRAG_THRESHOLD
	c^ = double ? {} : {at = p, ms = ms, has = true}
	return double
}

// Sets the selection to `r` (a window clicked, the whole output), clamped.
selection_set :: proc(s: ^Selection, r: Rect) {
	s.rect = rect_clamp(r, s.bounds)
	s.has_rect = !rect_empty(s.rect)
	s.dragging = false
}

// Moves the selection by `d`, its size kept: it stops at the edges of `bounds`.
selection_nudge :: proc(s: ^Selection, d: Point) {
	if !s.has_rect { return }
	r := s.rect
	r.x = clamp(r.x + d.x, s.bounds.x, s.bounds.x + s.bounds.w - r.w)
	r.y = clamp(r.y + d.y, s.bounds.y, s.bounds.y + s.bounds.h - r.h)
	s.rect = r
}

// Grows or shrinks the selection by `d` from its bottom-right corner: at least one pixel, never past `bounds`.
selection_resize :: proc(s: ^Selection, d: Point) {
	if !s.has_rect { return }
	r := s.rect
	r.w = clamp(r.w + d.x, 1, s.bounds.x + s.bounds.w - r.x)
	r.h = clamp(r.h + d.y, 1, s.bounds.y + s.bounds.h - r.y)
	s.rect = r
}

// The window to frame under `p`: the frontmost whose rect holds it, clamped to `bounds`. False when the system does not say
// where windows are, or no window is there.
frame_pick :: proc(wins: []capture.Window, p: Point, bounds: Rect, have_rects: bool) -> (r: Rect, ok: bool) {
	if !have_rects { return }
	w := capture.window_at(wins, p)
	if w == nil { return }
	r = rect_clamp(w.rect, bounds)
	return r, !rect_empty(r)
}

// The output whose rect holds `p`, -1 when none does.
output_at :: proc(outs: []capture.Output, p: Point) -> int {
	for o, i in outs { if rect_contains(o.rect, p) { return i } }
	return -1
}

// The output a full-screen window of `size` (logical) covers. The toolkit cannot put a window on a chosen output, and
// Wayland does not tell a client where its window is: the compositor puts it on the output it chooses. So:
//   `at`: where the system says the window is (X11, Windows): the output that holds it.
//   else the outputs of that size; among several, the one that holds `hint` (the pointer, when known), else the first.
// -1: no output (the list is empty).
output_for_window :: proc(outs: []capture.Output, size: [2]i32, at: Maybe(Point), hint: Maybe(Point)) -> int {
	if len(outs) == 0 { return -1 }
	if p, ok := at.?; ok {
		if i := output_at(outs, p); i >= 0 { return i }
	}
	first := -1
	for o, i in outs {
		if abs(o.rect.w - size.x) > 1 || abs(o.rect.h - size.y) > 1 { continue }
		if first < 0 { first = i }
		if p, ok := hint.?; ok && rect_contains(o.rect, p) { return i }
	}
	return first >= 0 ? first : 0
}
