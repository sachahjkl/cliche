package cliche

import "core:testing"
import capture "gt:capture"

// A picture of 4 x 2 physical pixels at scale 2 (2 x 1 logical), placed at (100, 50) on the desktop.
@(private = "file")
picture :: proc(order: capture.Pixel_Order) -> capture.Frame {
	px := make([]u8, 4 * 2 * 4, context.temp_allocator)
	for i in 0 ..< 8 {
		px[i * 4 + 0] = u8(i * 10)       // (R in RGBA, B in BGRA)
		px[i * 4 + 1] = u8(i * 10 + 1)
		px[i * 4 + 2] = u8(i * 10 + 2)
		px[i * 4 + 3] = 255
	}
	return {pixels = px, order = order, width = 4, height = 2, stride = 16, scale = 2, origin = {100, 50}}
}

@(test)
a_pixel_is_read_where_the_pointer_is :: proc(t: ^testing.T) {
	f := picture(.RGBA)
	c, ok := frame_pixel(f, {100, 50})
	testing.expect(t, ok)
	testing.expect_value(t, c, [4]u8{0, 1, 2, 255})
	c, ok = frame_pixel(f, {101, 50})   // (logical 1 is physical 2 at scale 2)
	testing.expect(t, ok)
	testing.expect_value(t, c, [4]u8{20, 21, 22, 255})
	_, ok = frame_pixel(f, {102, 50})
	testing.expect(t, !ok)
	_, ok = frame_pixel(f, {99, 50})
	testing.expect(t, !ok)
	// B, G, R, A in memory: the channels read in their place
	c, ok = frame_pixel(picture(.BGRA), {100, 50})
	testing.expect(t, ok)
	testing.expect_value(t, c, [4]u8{2, 1, 0, 255})
}

@(test)
a_colour_is_worded_for_the_clipboard :: proc(t: ^testing.T) {
	testing.expect_value(t, color_pick_text({255, 128, 0, 255}, false), "#ff8000")
	testing.expect_value(t, color_pick_text({255, 128, 0, 255}, true), "rgb(255, 128, 0)")
	testing.expect_value(t, color_pick_text({1, 2, 3, 0}, false), "#010203")
}
