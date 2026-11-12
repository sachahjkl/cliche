package cliche

// The QR code in a picture, read on the worker (gt:qr), as text for the clipboard.

import "core:strings"
import "core:unicode/utf8"
import qr "gt:qr"

// The text of the first QR code in the shot (owned). ok is false when none reads.
qr_read :: proc(shot: Shot, allocator := context.allocator) -> (text: string, ok: bool) {
	d, err := qr.decode_rgba(shot.rgba, shot.size.x, shot.size.y, shot.size.x * 4)
	if err != .None { return "", false }
	defer qr.decoded_destroy(&d)
	return qr_text(d.data, allocator), true
}

// A code's bytes as UTF-8. Most writers put UTF-8 in byte segments; the standard's default is ISO 8859-1, so bytes that
// are not UTF-8 are read as that.
qr_text :: proc(data: []u8, allocator := context.allocator) -> string {
	if utf8.valid_string(string(data)) { return strings.clone(string(data), allocator) }
	b := strings.builder_make(0, len(data) * 2, allocator)
	for c in data { strings.write_rune(&b, rune(c)) }
	return strings.to_string(b)
}
