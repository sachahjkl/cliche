package cliche

// What the worker reads from the screen (worker.odin calls these on its thread). gt:capture gives BGRA; the renderer's
// textures, the clipboard and the PNG encoder take RGBA: the worker swaps the channels once, here.

import capture "gt:capture"

// The desktop, the outputs and the windows, for a region. The frame's pixels are RGBA when it returns.
grab_desktop :: proc(s: ^capture.Session) -> Result_Desktop {
	r: Result_Desktop
	// (the lists first: what the picture shows is then at least as recent as where the windows were said to be)
	r.outputs = outputs_clone(capture.outputs(s))
	r.windows = windows_clone(capture.windows(s))
	r.have_rects = capture.windows_have_rects(s)
	r.frame, r.error = capture.desktop(s)
	if r.error != .None { return r }
	bgra_to_rgba(r.frame.pixels, r.frame.width, r.frame.height, r.frame.stride)
	return r
}

// The output under the pointer; the first output when the system does not say where the pointer is (Wayland).
grab_screen :: proc(s: ^capture.Session, pointer: proc() -> (Point, bool)) -> Result_Shot {
	outs := capture.outputs(s)
	if len(outs) == 0 { return {error = .Empty} }
	at := 0
	if p, ok := pointer(); ok { at = max(output_at(outs, p), 0) }
	f, err := capture.output(s, outs[at].id)
	if err != .None { return {error = flow_error_of(err)} }
	return {shot = shot_of_frame(&f, .Screen, bgra = true)}
}

// The window in front: its own picture, else the desktop cut to its rect (a backend that cannot take a window alone).
grab_window :: proc(s: ^capture.Session) -> Result_Shot {
	wins := capture.windows(s)
	front := -1
	for w, i in wins { if !w.minimized { front = i; break } }
	if front < 0 { return {error = .Empty} }
	target := wins[front]
	f, err := capture.window(s, target.id)
	if err == .None { return {shot = shot_of_frame(&f, .Window, bgra = true)} }
	if err != .Unsupported || !target.has_rect { return {error = flow_error_of(err)} }
	d, derr := capture.desktop(s)
	if derr != .None { return {error = flow_error_of(derr)} }
	defer capture.frame_free(&d)
	cut, ok := capture.crop(d, target.rect)
	if !ok { return {error = .Empty} }
	return {shot = shot_of_frame(&cut, .Window, bgra = true)}
}

// A frame as a shot: its rows packed, its channels swapped to RGBA when it is `bgra` (gt:capture's; a cut of the
// desktop of a region is RGBA already). The frame is freed.
shot_of_frame :: proc(f: ^capture.Frame, source: Source, bgra: bool) -> Shot {
	defer capture.frame_free(f)
	w, h := int(f.width), int(f.height)
	rgba := make([]u8, w * h * 4)
	for y in 0 ..< h {
		copy(rgba[y * w * 4:][:w * 4], f.pixels[y * int(f.stride):][:w * 4])
	}
	if bgra { bgra_to_rgba(rgba, f.width, f.height, f.width * 4) }
	return {rgba = rgba, size = {w, h}, source = source, scale = f.scale}
}

// Swaps blue and red in place.
bgra_to_rgba :: proc(pixels: []u8, width, height, stride: i32) {
	for y in 0 ..< int(height) {
		row := pixels[y * int(stride):][:int(width) * 4]
		for x := 0; x < len(row); x += 4 { row[x], row[x + 2] = row[x + 2], row[x] }
	}
}
