#+build !windows
package cliche

// The program's own knowledge of the pointer: none here. gt:capture says where it is (capture.pointer: the cursor
// sessions of Wayland, X11's pointer); this is what grab_screen falls back to when it cannot.
pointer_on_desktop :: proc() -> (p: Point, ok: bool) { return }
