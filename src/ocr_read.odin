package cliche

// The text in a picture, read on the worker (gt:ocr: Tesseract on Linux, Windows.Media.Ocr), for the clipboard.

import "core:strings"
import ocr "gt:ocr"

// The text of the shot (owned), or why there is none. `languages`: capture.ocr_languages ("": the user's).
ocr_read :: proc(shot: Shot, languages: string, allocator := context.allocator) -> (text: string, err: Flow_Error) {
	opts: ocr.Recognize_Options
	if languages != "" { opts.languages = strings.split(languages, "+", context.temp_allocator) }
	r, e := ocr.recognize(shot.rgba, shot.size.x, shot.size.y, shot.size.x * 4, .RGBA, opts)
	if e == .No_Engine || e == .No_Language { return "", .No_Ocr }
	if e != .None { return "", .No_Text }
	defer ocr.result_destroy(&r)
	trimmed := strings.trim_space(r.text)
	if trimmed == "" { return "", .No_Text }
	return strings.clone(trimmed, allocator), .None
}
