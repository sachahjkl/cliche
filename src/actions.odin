package cliche

import "core:strings"

// What happens to a picture once it is taken is a workflow (workflow.odin): a graph of steps the user edits. This file
// holds what the steps share: the picture taken, and the words of a notification.

// A picture taken: straight RGBA, rows from the top, no padding. The worker makes it; a workflow's run reads it.
Shot :: struct {
	rgba:   []u8,
	size:   [2]int,
	source: Source,
	scale:  f32,   // physical pixels per logical one (the editor's strokes are logical: 0 is 1)
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
