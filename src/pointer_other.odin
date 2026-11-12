#+build !windows
package cliche

// Wayland does not tell a client where the pointer is outside its own windows, and the toolkit reads no X11 pointer
// either: the screen capture takes the first output.
pointer_on_desktop :: proc() -> (p: Point, ok: bool) { return }
