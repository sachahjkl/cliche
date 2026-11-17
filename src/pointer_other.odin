#+build !windows
package cliche

// The program's own knowledge of the pointer: none here. gt:capture says where it is (capture.pointer: the cursor
// sessions of Wayland, X11's pointer); this is what grab_screen falls back to when it cannot.
pointer_on_desktop :: proc() -> (p: Point, ok: bool) { return }

// No way to move the pointer here (the toolkit has none; Wayland lets no client move the seat's): the scrolling
// capture asks the person to keep it over the page.
pointer_place :: proc(p: Point) -> bool { return false }
