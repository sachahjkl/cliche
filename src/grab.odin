package cliche

// What the worker reads from the screen (worker.odin calls these on its thread). The session gives RGBA
// (capture.set_pixel_order), what the renderer's textures, the clipboard and the PNG encoder take.

import capture "gt:capture"

// The desktop, the outputs and the windows, for a region. The frame's pixels are RGBA when it returns.
grab_desktop :: proc(s: ^capture.Session) -> Result_Desktop {
	r: Result_Desktop
	// (the lists first: what the picture shows is then at least as recent as where the windows were said to be)
	r.outputs = outputs_clone(capture.outputs(s))
	r.windows = windows_clone(capture.windows(s))
	r.have_rects = capture.windows_have_rects(s)
	r.frame, r.error = capture.desktop(s)
	return r
}

// The output under the pointer; the first output when the system does not say where the pointer is (Wayland).
grab_screen :: proc(s: ^capture.Session, pointer: proc() -> (Point, bool)) -> Result_Shot {
	outs := capture.outputs(s)
	if len(outs) == 0 { return {error = .Empty} }
	at := 0
	if p, ok := pointer(); ok { at = max(output_at(outs, p), 0) }
	timing_note("capture asked")
	f, err := capture.output(s, outs[at].id)
	timing_note("capture done")
	if err != .None { return {error = flow_error_of(err)} }
	shot := shot_of_frame(&f, .Screen)
	return {shot = shot}
}

// The window in front: its own picture, else the desktop cut to its rect (a backend that cannot take a window alone).
grab_window :: proc(s: ^capture.Session) -> Result_Shot {
	wins := capture.windows(s)
	front := -1
	for w, i in wins { if !w.minimized { front = i; break } }
	if front < 0 { return {error = .Empty} }
	target := wins[front]
	f, err := capture.window(s, target.id)
	if err == .None { return {shot = shot_of_frame(&f, .Window)} }
	if err != .Unsupported || !target.has_rect { return {error = flow_error_of(err)} }
	d, derr := capture.desktop(s)
	if derr != .None { return {error = flow_error_of(derr)} }
	defer capture.frame_free(&d)
	cut, ok := capture.crop(d, target.rect)
	if !ok { return {error = .Empty} }
	return {shot = shot_of_frame(&cut, .Window)}
}

// A frame as a shot, its pixels taken over: a frame of gt:capture is packed RGBA (the session's order) in the context's
// allocator, the shot's own. A frame of another kind is copied.
shot_of_frame :: proc(f: ^capture.Frame, source: Source) -> Shot {
	w, h := int(f.width), int(f.height)
	if int(f.stride) == w * 4 && f.order == .RGBA && f.allocator == context.allocator {
		shot := Shot{rgba = f.pixels, size = {w, h}, source = source, scale = f.scale}
		f.pixels = nil
		return shot
	}
	defer capture.frame_free(f)
	rgba := make([]u8, w * h * 4)
	for y in 0 ..< h {
		copy(rgba[y * w * 4:][:w * 4], f.pixels[y * int(f.stride):][:w * 4])
	}
	if f.order != .RGBA { bgra_to_rgba(rgba, f.width, f.height, f.width * 4) }
	return {rgba = rgba, size = {w, h}, source = source, scale = f.scale}
}

// Swaps blue and red in place.
bgra_to_rgba :: proc(pixels: []u8, width, height, stride: i32) {
	for y in 0 ..< int(height) {
		row := pixels[y * int(stride):][:int(width) * 4]
		for x := 0; x < len(row); x += 4 { row[x], row[x + 2] = row[x + 2], row[x] }
	}
}
