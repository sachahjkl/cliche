package cliche

// What happens to a picture once it is taken: a chain of actions, run in this order. Copy and Save run now; the others
// are the next layers (an uploader compatible with ShareX's .sxcu files, a QR code read from the picture, the editor).

After_Capture :: enum u8 {
	Copy,          // the picture on the clipboard
	Save,          // a PNG file in save.folder, named by save.name
	Upload,        // (to come) a custom HTTP uploader
	Qr,            // (to come) the QR codes the picture holds, read
	Open_Editor,   // (to come) the picture opened in cliche's editor
}

After_Capture_Set :: bit_set[After_Capture; u8]

// The actions this version runs; a set asks for the others in vain.
AFTER_CAPTURE_DONE :: After_Capture_Set{.Copy, .Save}

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
