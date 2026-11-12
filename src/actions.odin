package cliche

import "core:strings"

// What happens to a picture once it is taken: a chain of actions, run in this order. Copy and Save run now; the others
// are the next layers (an uploader compatible with ShareX's .sxcu files, the editor). Reading a QR code is a capture of
// its own (Purpose.Qr): its text, not the picture, is what it gives.

After_Capture :: enum u8 {
	Copy,          // the picture on the clipboard
	Save,          // a PNG file in save.folder, named by save.name
	Upload,        // (to come) a custom HTTP uploader
	Open_Editor,   // (to come) the picture opened in cliche's editor
}

After_Capture_Set :: bit_set[After_Capture; u8]

// The actions this version runs; a set asks for the others in vain.
AFTER_CAPTURE_DONE :: After_Capture_Set{.Copy, .Save}

// What a capture is for: a picture, through the chain; or the text of the QR code in it (cliche --qr), copied.
Purpose :: enum u8 { Picture, Qr }

// A picture taken: straight RGBA, rows from the top, no padding. The worker makes it; the chain reads it.
Shot :: struct {
	rgba:   []u8,
	size:   [2]int,
	source: Source,
}

shot_free :: proc(s: ^Shot) {
	delete(s.rgba)
	s^ = {}
}

// A notification's body: the text up to NOTICE_TEXT_MAX bytes (a whole character), with an ellipsis when cut.
NOTICE_TEXT_MAX :: 200

notice_text :: proc(text: string) -> string {
	if len(text) <= NOTICE_TEXT_MAX { return text }
	end := NOTICE_TEXT_MAX
	for end > 0 && text[end] & 0xC0 == 0x80 { end -= 1 }   // (not inside a UTF-8 sequence)
	return strings.concatenate({text[:end], "…"}, context.temp_allocator)
}
