package cliche

// The screen's colour picker: the overlay (overlay.odin) shows the frozen desktop with its magnifier, and a click takes
// the colour of the pixel under the pointer, from the picture the worker read (no new capture). Its words go to the
// clipboard: "#rrggbb", or "rgb(r, g, b)" with Shift. The app copies them and says them (app_color_picked). What is
// here is pure, tested without a window (color_pick_test.odin).

import "core:fmt"
import "core:math"
import capture "gt:capture"

// The colour of the pixel at `p` (logical, on the desktop) in `f` (R, G, B, A: the session's order). False: `p` is
// outside the picture.
frame_pixel :: proc(f: capture.Frame, p: Point) -> (c: [4]u8, ok: bool) {
	scale := f.scale > 0 ? f.scale : 1
	x := i32(math.floor(f32(p.x - f.origin.x) * scale))
	y := i32(math.floor(f32(p.y - f.origin.y) * scale))
	if x < 0 || y < 0 || x >= f.width || y >= f.height { return }
	at := int(y) * int(f.stride) + int(x) * 4
	if at + 4 > len(f.pixels) { return }
	px := f.pixels[at:][:4]
	if f.order == .BGRA { return {px[2], px[1], px[0], px[3]}, true }
	return {px[0], px[1], px[2], px[3]}, true
}

// The words of a colour for the clipboard: "#rrggbb", or with `rgb` "rgb(r, g, b)" (the alpha left out: a screen's
// pixel is opaque). Temp allocator.
color_pick_text :: proc(c: [4]u8, rgb: bool) -> string {
	if rgb { return fmt.tprintf("rgb(%d, %d, %d)", c.r, c.g, c.b) }
	return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)
}
