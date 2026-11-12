package cliche

import "core:testing"

STAMP :: Stamp{year = 2026, month = 3, day = 7, hour = 9, minute = 5, second = 4, milli = 42}

@(test)
name_fields :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"cliche_%Y-%m-%d_%H-%M-%S", "cliche_2026-03-07_09-05-04.png"},
		{"%s %f", "region 042.png"},
		{"100%% %q", "100% %q.png"},
		{"shot.png", "shot.png"},
		{"a/b:c?", "a-b-c-.png"},
		{"..", "cliche.png"},
		{"   ", "cliche.png"},
		{"end%", "end%.png"},
	}
	for c in cases {
		got := name_expand(c[0], STAMP, .Region, context.temp_allocator)
		testing.expectf(t, got == c[1], "%q: %q, not %q", c[0], got, c[1])
	}
}

@(test)
name_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, name_numbered("a.png", 1, context.temp_allocator), "a.png")
	testing.expect_value(t, name_numbered("a.png", 2, context.temp_allocator), "a (2).png")
	testing.expect_value(t, name_numbered("a.b.png", 3, context.temp_allocator), "a.b (3).png")
	testing.expect_value(t, name_numbered("noext", 2, context.temp_allocator), "noext (2)")
	testing.expect_value(t, name_numbered(".png", 2, context.temp_allocator), ".png (2)")
}

// A name made for PNG files takes the extension of the format it is saved in.
@(test)
a_name_takes_its_format_extension :: proc(t: ^testing.T) {
	testing.expect_value(t, name_with_extension("cliche-1.png", ".jpg"), "cliche-1.jpg")
	testing.expect_value(t, name_with_extension("shot.PNG", ".webp"), "shot.webp")
	testing.expect_value(t, name_with_extension("notes", ".png"), "notes.png")
	testing.expect_value(t, name_with_extension("a.tar", ".jpg"), "a.tar.jpg")
}
