package cliche

import "core:testing"
import qr "gt:qr"

@(test)
qr_text_utf8_or_latin1 :: proc(t: ^testing.T) {
	testing.expect_value(t, qr_text(transmute([]u8)string("ça va"), context.temp_allocator), "ça va")
	latin1 := []u8{0xE7, 'a'}   // ("ça" in ISO 8859-1: not UTF-8)
	testing.expect_value(t, qr_text(latin1, context.temp_allocator), "ça")
	testing.expect_value(t, qr_text(nil, context.temp_allocator), "")
}

// A shot of a code, drawn 3 pixels a module on white: read back.
@(test)
qr_read_a_shot :: proc(t: ^testing.T) {
	text := "https://github.com/sachahjkl/cliche"
	code, _ := qr.encode(text)
	defer qr.destroy(&code)
	scale, side := 3, (code.size + 2 * qr.QUIET_ZONE) * 3
	rgba := make([]u8, side * side * 4, context.temp_allocator)
	for y in 0 ..< side {
		for x in 0 ..< side {
			dark := qr.module(code, x / scale - qr.QUIET_ZONE, y / scale - qr.QUIET_ZONE)
			v: u8 = dark ? 0 : 255
			rgba[(y * side + x) * 4 + 0], rgba[(y * side + x) * 4 + 1], rgba[(y * side + x) * 4 + 2], rgba[(y * side + x) * 4 + 3] = v, v, v, 255
		}
	}
	got, ok := qr_read({rgba = rgba, size = {side, side}}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, got, text)
	blank := make([]u8, 64 * 64 * 4, context.temp_allocator)
	_, found := qr_read({rgba = blank, size = {64, 64}}, context.temp_allocator)
	testing.expect(t, !found)
}

@(test)
notice_text_cut_on_a_character :: proc(t: ^testing.T) {
	testing.expect_value(t, notice_text("short"), "short")
	long := make([]u8, NOTICE_TEXT_MAX + 10, context.temp_allocator)
	for &c in long { c = 'a' }
	long[NOTICE_TEXT_MAX - 1], long[NOTICE_TEXT_MAX] = 0xC3, 0xA7   // ("ç" across the limit)
	got := notice_text(string(long))
	testing.expect_value(t, len(got), NOTICE_TEXT_MAX - 1 + len("…"))
}
