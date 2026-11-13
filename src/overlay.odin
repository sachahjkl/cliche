package cliche

// The overlay of a region: a layer surface on every output that shows it as it was at the trigger (the frozen picture the
// worker read, each output's own at its own scale), dimmed outside what is chosen. One selection, on the desktop: it is
// chosen on any screen, or across screens (a drag keeps coming to the surface it started on, past its edges). It works
// the same on every compositor with a layer shell: no transparency, nothing over the other programs' windows but a
// picture of them.
//
// With no layer shell: one fullscreen window. Wayland does not let a client pick the output of its window: the
// compositor puts it where it chooses, and says which output that is (platform.window_output_name, from
// wl_surface.enter); until it has, and where it cannot, output_for_window guesses from the window's size (and the
// pointer, where the system says it). The window shows that output; a selection stays on it.
//
// What the user does:
//   drag                 a rectangle; it stays, the keys adjust it (region.confirm_on_release: taken at the release)
//   click                the window framed under the pointer (region.frame_windows, when the system says where windows
//                        are); inside a rectangle
//                        already chosen: that rectangle
//   Enter, Space         the rectangle chosen, else the whole output under the pointer
//   arrows / Shift       move the rectangle a pixel (ten with Ctrl) / grow or shrink it from its bottom-right corner
//   Escape, right click  the rectangle dropped, or, with none, the region given up
// The decision is acted on after the frame (overlay_after_frame): the window is not hidden from inside its own frame.

import "core:fmt"
import "core:math"
import capture "gt:capture"
import "gt:draw"
import "gt:font"
import "gt:host"
import "gt:platform"
import "gt:render"
import "gt:ui"

MAGNIFIER_SIDE_PX :: 15    // logical pixels of the picture the magnifier shows, on each side
MAGNIFIER_ZOOM    :: 8     // how much it enlarges them
MAGNIFIER_GAP_PX  :: 24    // between the pointer and the magnifier
NUDGE_FAST        :: 10    // pixels a step with Ctrl
OUTLINE_PX        :: 1     // the outline of what is chosen, in the window's pixels (scaled)

Overlay_Decision :: enum u8 { None, Confirm, Cancel }

// One window of the overlay: a layer surface over one output, or the fullscreen window of a desktop with no layer shell.
// Allocated on its own: its host's address is the platform's.
Overlay_Surface :: struct {
	host:     host.Host,
	opened:   bool,
	visible:  bool,
	in_use:   bool,             // shown at this show (its output is there)
	tex:      render.Texture,   // the frozen picture of the output it covers (RGBA), uploaded at each show
	tex_size: [2]int,
	place:    Frame_Place,      // where the texture's picture is on the desktop
	out:      Rect,             // the output it covers, logical
}

Overlay :: struct {
	// a layer surface per output, kept from one show to the next (the renderer's own window among them is never closed);
	// with no layer shell, one fullscreen window the compositor places, whose output is guessed
	surfaces: [dynamic]^Overlay_Surface,
	layer:    bool,
	visible:  bool,             // the surfaces are shown
	bounds:   Rect,             // what the selection stays in: every output covered (their bounding rectangle)
	sel:      Selection,
	pointer:  Point,            // logical, on the desktop
	has_pointer: bool,
	hover:    Rect,             // the window framed under the pointer
	has_hover: bool,
	decision: Overlay_Decision,
	chosen:   Rect,             // what Confirm takes
}

// Opens what is missing and shows the overlay over the desktop the worker read: a layer surface on every output, so a
// region is chosen on any screen, or across them. False: no window could open.
overlay_show :: proc(app: ^App) -> bool {
	o := &app.overlay
	if !app.has_desktop { return false }
	o.decision = .None
	o.has_hover = false
	o.has_pointer = false
	if !overlay_open_layers(app) && !overlay_open_window(app) { return false }
	ok := false
	for s in o.surfaces {
		if !s.opened || !s.in_use { continue }
		if overlay_upload(app, s) { ok = true } else { s.in_use = false }
	}
	if !ok { return false }
	o.bounds = overlay_bounds(o)
	selection_reset(&o.sel, o.bounds)
	token := app_take_token(app)
	defer delete(token)
	// (the pointer's screen last: a compositor that gives the keyboard to the last surface shown gives it that one)
	at := overlay_pointer_output(app)
	for pass in 0 ..< 2 {
		for s in o.surfaces {
			if !s.in_use || (s.out == at) != (pass == 1) { continue }
			if !o.layer { platform.set_fullscreen(s.host.win, true) }
			if !s.visible {
				host.host_show(&s.host)
				s.visible = true
			}
			if !o.layer { platform.raise_window_token(s.host.win, token) }   // (a layer surface has the keyboard from its showing)
			s.host.settle = max(s.host.settle, 3)
		}
	}
	o.visible = true
	return true
}

// A layer surface on every output: those of outputs gone are closed (but the renderer's own window, kept hidden), the
// missing ones opened. False: there is no layer shell (not one could open), or no output is known.
@(private = "file")
overlay_open_layers :: proc(app: ^App) -> bool {
	o := &app.overlay
	outs := app.desktop.outputs
	if len(outs) == 0 { return false }
	if len(o.surfaces) > 0 && !o.layer { return false }   // (no layer shell, found before)
	for s in o.surfaces { s.in_use = false }
	for i := 0; i < len(o.surfaces); {
		s := o.surfaces[i]
		kept := false
		for out in outs { if out.rect == s.out { kept = true } }
		if kept || app.shared.main == &s.host { i += 1; continue }
		overlay_surface_close(app, s)
		ordered_remove(&o.surfaces, i)
	}
	for out in outs {
		if out.rect.w <= 0 || out.rect.h <= 0 { continue }
		found: ^Overlay_Surface
		for s in o.surfaces { if s.out == out.rect { found = s } }
		if found == nil {
			found = new(Overlay_Surface)
			area := [4]int{int(out.rect.x), int(out.rect.y), int(out.rect.w), int(out.rect.h)}
			open := host.Open{title = "cliche region", size = {max(area[2], 1), max(area[3], 1)}, overlay = true, overlay_area = area, overlay_keyboard = .Exclusive}
			if !host.host_open(&found.host, &app.shared, open, overlay_build, app) {
				free(found)
				if len(o.surfaces) == 0 { return false }
				continue   // (this output alone: the others still show)
			}
			found.opened, found.out = true, out.rect
			found.host.input = overlay_input
			found.host.after_input = 2
			app_wake_add(app, found.host.win)
			append(&o.surfaces, found)
		}
		found.in_use = true
	}
	o.layer = true
	return true
}

// No layer shell: one fullscreen window the compositor places (it shows the output it lands on; a selection stays on it).
@(private = "file")
overlay_open_window :: proc(app: ^App) -> bool {
	o := &app.overlay
	if len(o.surfaces) == 0 {
		s := new(Overlay_Surface)
		if !host.host_open(&s.host, &app.shared, {title = "cliche region", size = {1280, 720}}, overlay_build, app) {
			free(s)
			fmt.eprintln("cliche: the region's window cannot open")
			return false
		}
		s.opened = true
		s.host.input = overlay_input
		s.host.after_input = 2
		app_wake_add(app, s.host.win)
		append(&o.surfaces, s)
	}
	o.layer = false
	s := o.surfaces[0]
	s.in_use = true
	s.out = overlay_output(app, s)
	return true
}

@(private = "file")
overlay_surface_close :: proc(app: ^App, s: ^Overlay_Surface) {
	if s.tex != 0 { render.destroy_texture(&app.shared.r, s.tex) }
	app_wake_remove(app, s.host.win)
	host.host_close(&s.host)
	free(s)
}

// The bounding rectangle of the outputs shown.
@(private = "file")
overlay_bounds :: proc(o: ^Overlay) -> Rect {
	x0, y0, x1, y1 := max(i32), max(i32), min(i32), min(i32)
	for s in o.surfaces {
		if !s.in_use { continue }
		x0, y0 = min(x0, s.out.x), min(y0, s.out.y)
		x1, y1 = max(x1, s.out.x + s.out.w), max(y1, s.out.y + s.out.h)
	}
	if x1 <= x0 || y1 <= y0 { return {} }
	return {x0, y0, x1 - x0, y1 - y0}
}

overlay_hide :: proc(app: ^App) {
	o := &app.overlay
	if !o.visible { return }
	for s in o.surfaces {
		if s.visible { host.host_hide(&s.host) }
		s.visible = false
	}
	o.visible = false
	o.decision = .None
}

// The hosts of the overlay's windows: those shown (`shown`), else every one opened.
overlay_hosts :: proc(app: ^App, list: ^[dynamic]^host.Host, shown: bool) {
	for s in app.overlay.surfaces {
		if s.opened && (!shown || s.visible) { append(list, &s.host) }
	}
}

// The textures go with the renderer: before the windows close.
overlay_destroy :: proc(app: ^App) {
	for s in app.overlay.surfaces {
		if s.tex != 0 { render.destroy_texture(&app.shared.r, s.tex) }
		s.tex = 0
	}
}

// After the windows closed (app_windows_close): their memory.
overlay_free :: proc(app: ^App) {
	for s in app.overlay.surfaces { free(s) }
	delete(app.overlay.surfaces)
	app.overlay.surfaces = nil
}

// Before the frame: the output the fullscreen window covers now (its size is known once it is fullscreen).
overlay_prepare :: proc(app: ^App) {
	o := &app.overlay
	if o.layer || len(o.surfaces) == 0 { return }   // (a layer surface is on the output it was made for)
	s := o.surfaces[0]
	out := overlay_output(app, s)
	if out == s.out { return }
	s.out = out
	_ = overlay_upload(app, s)
	o.bounds = out
	if !o.sel.has_rect { selection_reset(&o.sel, out) } else { o.sel.bounds = out; selection_set(&o.sel, o.sel.rect) }
}

// After the frames: what the user decided, acted on.
overlay_after_frame :: proc(app: ^App) {
	o := &app.overlay
	switch o.decision {
	case .None:
	case .Confirm:
		o.decision = .None
		app_region_confirmed(app, o.chosen)
	case .Cancel:
		o.decision = .None
		app_region_cancelled(app)
	}
}

// The output the pointer is on, as the capture session said; else the first.
@(private = "file")
overlay_pointer_output :: proc(app: ^App) -> Rect {
	outs := app.desktop.outputs
	if len(outs) == 0 { return {} }
	if app.desktop.has_pointer_output {
		for o in outs { if o.id == app.desktop.pointer_output { return o.rect } }
	}
	return outs[0].rect
}

// The output shown under `p`: the one that holds it, else the selection's bounds.
@(private = "file")
overlay_out_at :: proc(o: ^Overlay, p: Point) -> Rect {
	for s in o.surfaces { if s.in_use && rect_contains(s.out, p) { return s.out } }
	return o.bounds
}

// The surface of `h`.
@(private = "file")
overlay_surface_of :: proc(app: ^App, h: ^host.Host) -> ^Overlay_Surface {
	for s in app.overlay.surfaces { if &s.host == h { return s } }
	return nil
}

// The frozen picture of the output a surface covers, as a texture: that output's own part (capture.desktop_parts), at its
// own scale, so a screen at a lower scale than another is shown pixel for pixel, not enlarged by the composed desktop and
// shrunk again. A part that does not hold the output (none says where it is): the parts composed.
@(private = "file")
overlay_upload :: proc(app: ^App, s: ^Overlay_Surface) -> bool {
	parts := app.desktop.parts
	if len(parts) == 0 { return false }
	f: capture.Frame
	composed := false
	if i := capture.part_holding(parts, s.out); i >= 0 {
		f = parts[i]
	} else {
		ok: bool
		f, ok = capture.compose(parts)
		if !ok { return false }
		composed = true
	}
	defer if composed { capture.frame_free(&f) }
	r := &app.shared.r
	if s.tex != 0 && s.tex_size != {int(f.width), int(f.height)} {
		render.destroy_texture(r, s.tex)
		s.tex = 0
	}
	if s.tex == 0 {
		s.tex = render.create_texture_rgba(r, int(f.width), int(f.height), mips = false)
		s.tex_size = {int(f.width), int(f.height)}
	}
	if s.tex == 0 { return false }
	render.update_texture_rgba(r, s.tex, 0, 0, int(f.width), int(f.height), f.pixels, int(f.stride))
	s.place = {f.origin, f.scale}
	return true
}

// The output the fullscreen window covers: from its size (logical) and the pointer, as output_for_window decides.
@(private = "file")
overlay_output :: proc(app: ^App, s: ^Overlay_Surface) -> Rect {
	outs := app.desktop.outputs
	if len(outs) == 0 {
		parts := app.desktop.parts
		return len(parts) > 0 ? {parts[0].origin.x, parts[0].origin.y, 0, 0} : {}
	}
	// (the compositor's word first: two monitors of the same size cannot be told apart by the window's)
	if name := platform.window_output_name(s.host.win); name != "" {
		for out in outs { if out.name == name { return out.rect } }
	}
	scale := overlay_scale(s)
	size := [2]i32{i32(math.round(f32(s.host.win.size.x) / scale)), i32(math.round(f32(s.host.win.size.y) / scale))}
	hint: Maybe(Point)
	if p, ok := pointer_on_desktop(); ok { hint = p }
	i := output_for_window(outs, size, nil, hint)
	return outs[max(i, 0)].rect
}

@(private = "file")
overlay_scale :: proc(s: ^Overlay_Surface) -> f32 {
	sc := s.host.win != nil ? s.host.win.dpi_scale : 1
	return sc > 0 ? sc : 1
}

// A point of a surface (its pixels) on the desktop (logical). A drag that leaves the surface it started on still comes to
// it (the compositor's implicit grab), past its edges: the point is then on another output.
@(private = "file")
overlay_point :: proc(s: ^Overlay_Surface, p: [2]f32) -> Point {
	sc := overlay_scale(s)
	return {s.out.x + i32(math.floor(p.x / sc)), s.out.y + i32(math.floor(p.y / sc))}
}

@(private = "file")
overlay_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	o := &app.overlay
	s := overlay_surface_of(app, h)
	if s == nil { return nil }
	frames := app.desktop.have_rects && app.settings.frame_windows
	before := overlay_marks(o)
	for e in events {
		#partial switch e.kind {
		case .Mouse_Move:
			o.pointer, o.has_pointer = overlay_point(s, e.pos), true
			selection_move(&o.sel, o.pointer)
		case .Mouse_Press:
			p := overlay_point(s, e.pos)
			o.pointer, o.has_pointer = p, true
			if e.button == .Right { overlay_escape(o); continue }
			if e.button != .Left { continue }
			if o.sel.has_rect && rect_contains(o.sel.rect, p) {   // (inside what is chosen: that is taken)
				overlay_confirm(o, o.sel.rect)
				continue
			}
			o.sel.has_rect = false
			selection_press(&o.sel, p)
		case .Mouse_Release:
			if e.button != .Left { continue }
			p := overlay_point(s, e.pos)
			switch selection_release(&o.sel, p) {
			case .Click:
				if r, ok := frame_pick(app.desktop.windows, p, overlay_out_at(o, p), frames); ok { overlay_confirm(o, r) }
			case .Rect:
				if app.settings.confirm_on_release { overlay_confirm(o, o.sel.rect) }
			case .None:
			}
		case .Key_Press:
			overlay_key(o, e, o.has_pointer ? overlay_out_at(o, o.pointer) : s.out)
		}
	}
	// (the window framed under the pointer, while no rectangle is chosen or dragged)
	o.has_hover = false
	if o.has_pointer && !o.sel.dragging && !o.sel.has_rect {
		o.hover, o.has_hover = frame_pick(app.desktop.windows, o.pointer, overlay_out_at(o, o.pointer), frames)
	}
	// (another screen draws again only when what it shows changed: each frame of a surface waits for its own screen's
	// refresh, and the loop draws them one after the other, so a frame of every screen at each move slows them all)
	after := overlay_marks(o)
	if after != before {
		for other in o.surfaces {
			if other == s || !other.visible { continue }
			if overlay_marks_touch(before, other.out) || overlay_marks_touch(after, other.out) { other.host.settle = max(other.host.settle, 2) }
		}
	}
	return nil   // (the overlay's interface is its picture: nothing goes to widgets)
}

// What the surfaces draw of the selection: the rectangle lit (chosen or framed) and the pointer (the magnifier).
@(private = "file")
Overlay_Marks :: struct {
	lit:         Rect,
	has_lit:     bool,
	pointer:     Point,
	has_pointer: bool,
}

@(private = "file")
overlay_marks :: proc(o: ^Overlay) -> (m: Overlay_Marks) {
	switch {
	case o.sel.has_rect: m.lit, m.has_lit = o.sel.rect, true
	case o.has_hover:    m.lit, m.has_lit = o.hover, true
	}
	m.pointer, m.has_pointer = o.pointer, o.has_pointer
	return
}

// Whether marks show on the output `out`: the lit rectangle meets it (its outline included), or the pointer is on it.
@(private = "file")
overlay_marks_touch :: proc(m: Overlay_Marks, out: Rect) -> bool {
	if m.has_pointer && rect_contains(out, m.pointer) { return true }
	if !m.has_lit { return false }
	l := Rect{m.lit.x - 1, m.lit.y - 1, m.lit.w + 2, m.lit.h + 2}
	return !rect_empty(rect_clamp(l, out))
}

@(private = "file")
overlay_key :: proc(o: ^Overlay, e: platform.Event, screen: Rect) {
	step: i32 = .Ctrl in e.mods ? NUDGE_FAST : 1
	d: Point
	#partial switch e.key {
	case .Escape: overlay_escape(o); return
	case .Return, .Space:
		overlay_confirm(o, o.sel.has_rect ? o.sel.rect : screen)   // (none chosen: the screen under the pointer)
		return
	case .Left:  d = {-step, 0}
	case .Right: d = {step, 0}
	case .Up:    d = {0, -step}
	case .Down:  d = {0, step}
	case: return
	}
	if .Shift in e.mods { selection_resize(&o.sel, d) } else { selection_nudge(&o.sel, d) }
}

@(private = "file")
overlay_escape :: proc(o: ^Overlay) {
	if o.sel.has_rect || o.sel.dragging {
		selection_reset(&o.sel, o.bounds)
		return
	}
	o.decision = .Cancel
}

@(private = "file")
overlay_confirm :: proc(o: ^Overlay, r: Rect) {
	if rect_empty(r) { return }
	o.chosen = r
	o.decision = .Confirm
}

// What one frame draws, from the overlay's state (frame memory).
@(private = "file")
Overlay_Draw :: struct {
	tex:        render.Texture,
	frame:      Frame_Place,
	out:        Rect,
	win_scale:  f32,
	dim:        f32,       // how dark the picture is outside what is chosen (region.dim)
	lit:        Rect,      // what is chosen or framed (empty: none)
	has_lit:    bool,
	pointer:    Point,
	magnifier:  bool,
	label:      string,
	font:       font.Font_Id,
	font_size:  f32,
}

// Where the frozen picture is on the desktop.
@(private = "file")
Frame_Place :: struct { origin: [2]i32, scale: f32 }

@(private = "file")
overlay_build :: proc(h: ^host.Host, size: ui.Vec2) {
	app := (^App)(h.user)
	o := &app.overlay
	s := overlay_surface_of(app, h)
	if s == nil { return }
	d := ui.frame_new(Overlay_Draw)
	// (the magnifier on the screen the pointer is on)
	d^ = {tex = s.tex, frame = s.place, out = s.out, win_scale = overlay_scale(s), dim = app.settings.dim,
		pointer = o.pointer, magnifier = app.settings.magnifier && o.has_pointer && rect_contains(s.out, o.pointer), font = app.shared.font, font_size = ui.font_size()}
	switch {
	case o.sel.has_rect:  d.lit, d.has_lit = o.sel.rect, true
	case o.has_hover:     d.lit, d.has_lit = o.hover, true
	}
	if d.has_lit { d.label = fmt.tprintf("%d x %d", d.lit.w, d.lit.h) } else if o.has_pointer { d.label = fmt.tprintf("%d, %d", o.pointer.x, o.pointer.y) }
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(size.x), height = ui.px(size.y)})
	b := ui.build_box({}, "###overlay")
	b.custom, b.custom_user = overlay_draw, d
}

// Logical (desktop) to the window's pixels.
@(private = "file")
to_window :: proc(d: ^Overlay_Draw, r: Rect) -> draw.Rect {
	s := d.win_scale
	x0 := f32(r.x - d.out.x) * s
	y0 := f32(r.y - d.out.y) * s
	return {{x0, y0}, {x0 + f32(r.w) * s, y0 + f32(r.h) * s}}
}

// Logical (desktop) to the picture's pixels.
@(private = "file")
to_picture :: proc(d: ^Overlay_Draw, r: Rect) -> draw.Rect {
	s := d.frame.scale
	x0 := f32(r.x - d.frame.origin.x) * s
	y0 := f32(r.y - d.frame.origin.y) * s
	return {{x0, y0}, {x0 + f32(r.w) * s, y0 + f32(r.h) * s}}
}

@(private = "file")
overlay_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Overlay_Draw)(user)
	if d.tex == 0 { return }
	win := to_window(d, d.out)
	draw.image(dc, d.tex, win, to_picture(d, d.out))
	dim := draw.Color{0, 0, 0, d.dim}
	if !d.has_lit {
		draw.rect(dc, win, dim)
	} else {
		l := to_window(d, d.lit)
		// (four bands around what is chosen: it stays as bright as the screen was)
		draw.rect(dc, {win.min, {win.max.x, l.min.y}}, dim)
		draw.rect(dc, {{win.min.x, l.max.y}, win.max}, dim)
		draw.rect(dc, {{win.min.x, l.min.y}, {l.min.x, l.max.y}}, dim)
		draw.rect(dc, {{l.max.x, l.min.y}, {win.max.x, l.max.y}}, dim)
		px := max(math.round(OUTLINE_PX * d.win_scale), 1)
		draw.rect(dc, l, {1, 1, 1, 0.9}, 0, px)
	}
	if d.magnifier { overlay_magnifier(d, dc, win) }
}

// Near the pointer: the pixels around it enlarged, a cross on the one under it, and the position or the size.
@(private = "file")
overlay_magnifier :: proc(d: ^Overlay_Draw, dc: ^draw.Context, win: draw.Rect) {
	s := d.win_scale
	side := f32(2 * MAGNIFIER_SIDE_PX + 1)
	box := side * MAGNIFIER_ZOOM * s   // (window pixels)
	p := to_window(d, {d.pointer.x, d.pointer.y, 1, 1}).min
	at := p + {MAGNIFIER_GAP_PX * s, MAGNIFIER_GAP_PX * s}
	// (kept inside the window: it flips to the other side of the pointer near an edge)
	if at.x + box > win.max.x { at.x = p.x - MAGNIFIER_GAP_PX * s - box }
	if at.y + box > win.max.y { at.y = p.y - MAGNIFIER_GAP_PX * s - box }
	dst := draw.Rect{at, at + {box, box}}
	src := to_picture(d, {d.pointer.x - MAGNIFIER_SIDE_PX, d.pointer.y - MAGNIFIER_SIDE_PX, i32(side), i32(side)})
	draw.rect(dc, dst, {0, 0, 0, 1})
	draw.image(dc, d.tex, dst, src)
	cell := MAGNIFIER_ZOOM * s
	c := at + {MAGNIFIER_SIDE_PX * cell, MAGNIFIER_SIDE_PX * cell}
	draw.rect(dc, {c, c + {cell, cell}}, {1, 1, 1, 0.9}, 0, max(math.round(s), 1))
	draw.rect(dc, dst, {1, 1, 1, 0.6}, 0, max(math.round(s), 1))
	if d.label != "" {
		fs := d.font_size
		draw.rect(dc, {{dst.min.x, dst.max.y}, {dst.max.x, dst.max.y + fs * 1.6}}, {0, 0, 0, 0.8})
		draw.text(dc, d.font, fs, {dst.min.x + fs * 0.5, dst.max.y + fs * 1.15}, {1, 1, 1, 1}, d.label)
	}
}
