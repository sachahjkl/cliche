#+build windows
package cliche

// Where the pointer is on the desktop: the screen capture takes the output under it. GetCursorPos is safe on any thread.
//
// (cliche declares per-monitor DPI awareness through the toolkit, so the point is in physical pixels. gt:capture's
// desktop is in logical pixels; with every monitor at 100 % they are the same. With mixed scales the point can fall on the
// wrong output: gt:capture does not say how it maps Windows' monitors to logical rects, so no conversion is attempted.)

import win "core:sys/windows"

pointer_on_desktop :: proc() -> (p: Point, ok: bool) {
	pt: win.POINT
	if !win.GetCursorPos(&pt) { return }
	return {pt.x, pt.y}, true
}

// Moves the pointer to `p` (the desktop's logical pixels, taken as physical as above): the scrolling capture's wheel
// goes to the window under it, and the person can let go of the mouse.
pointer_place :: proc(p: Point) -> bool {
	return bool(win.SetCursorPos(p.x, p.y))
}
