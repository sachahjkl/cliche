package cliche

// The overlay of a region: one fullscreen window that shows the desktop as it was at the trigger (the frozen picture the
// worker read), dimmed outside what is chosen. It works the same on every compositor: no layer surface, no transparency,
// nothing over the other programs' windows but a picture of them.
//
// Wayland does not let a client pick the output of its window: the compositor puts the fullscreen window where it
// chooses, and says which output that is (platform.window_output_name, from wl_surface.enter); until it has, and where
// it cannot, output_for_window guesses from the window's size (and the pointer, where the system says it). The window
// shows that output's part of the picture; a selection stays on it.
//
// What the user does:
//   drag                 a rectangle; it stays, the mouse and the keys adjust it (region.confirm_on_release: taken at
//                        the release)
//   drag a grip          a corner or an edge of the rectangle chosen resizes it, its inside moves it (the pointer's
//                        shape says which); a press elsewhere draws a new one
//   click                the window framed under the pointer (region.frame_windows, when the system says where windows
//                        are)
//   double click inside  the rectangle chosen
//   Enter, Space         the rectangle chosen, else the whole output
//   arrows / Shift       move the rectangle a pixel (ten with Ctrl) / grow or shrink it from its bottom-right corner
//   Escape, right click  the rectangle dropped, or, with none, the region given up
// The colour picker (`picker`) is the same window, undimmed, with no rectangle: a click takes the colour under the
// pointer (Shift: as rgb()), Enter the one under the pointer, the arrows move that point a pixel (ten with Ctrl),
// Escape gives it up.
// The decision is acted on after the frame (overlay_after_frame): the window is not hidden from inside its own frame.

import "core:fmt"
import "core:log"
import "core:math"
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
HANDLE_PX         :: 7     // the side of a grip's square on the rectangle chosen, in the window's pixels (scaled)

Overlay_Decision :: enum u8 { None, Confirm, Cancel, Pick }

Overlay :: struct {
	host:     host.Host,
	opened:   bool,
	visible:  bool,
	tex:      render.Texture,   // the frozen desktop (RGBA), uploaded at each show
	tex_size: [2]int,
	out:      Rect,             // the output the window covers, logical
	sel:      Selection,
	pointer:  Point,            // logical, on the desktop
	has_pointer: bool,
	hover:    Rect,             // the window framed under the pointer
	has_hover: bool,
	decision: Overlay_Decision,
	chosen:   Rect,             // what Confirm takes
	picker:   bool,             // the colour picker: a click takes a pixel's colour, no rectangle
	picked:   [4]u8,            // what Pick takes
	pick_rgb: bool,             // its words as rgb() (Shift)
	hover_grip: Grip,           // the grip of the rectangle under the pointer (its shape)
	clicks:   Click_Track,      // the presses, for a double click
	// a layer surface over one output (platform.open_overlay: no window animation, the keyboard at once), on `out`;
	// false: a fullscreen window the compositor places (a desktop with no layer shell), whose output is guessed
	layer:    bool,
}

// Opens (the first time) and shows the overlay over the desktop the worker read: a region's, or the colour picker
// (`picker`). False: no window could open.
overlay_show :: proc(app: ^App, picker := false) -> bool {
	o := &app.overlay
	if !app.has_desktop { return false }
	out := overlay_pointer_output(app)
	// (a layer surface stays on the output it was made for: another output, another surface; the renderer's own window
	// stays, on its output)
	if o.opened && o.layer && o.out != out && app.shared.main != &o.host {
		app_wake_remove(app, o.host.win)
		app_host_close(app, &o.host)
		o.opened, o.visible = false, false
	}
	if !o.opened {
		area := [4]int{int(out.x), int(out.y), int(out.w), int(out.h)}
		layer := host.Open_Options{title = "cliche region", size = {max(area[2], 1), max(area[3], 1)}, overlay = true, overlay_area = area, overlay_keyboard = .Exclusive}
		o.layer = out.w > 0 && host.host_open(&o.host, &app.shared, layer, overlay_build, app)
		if !o.layer && !host.host_open(&o.host, &app.shared, {title = "cliche region", size = {1280, 720}}, overlay_build, app) {
			log.error("the region's window cannot open")
			return false
		}
		if o.layer { o.out = out }
		o.opened = true
		app_standard_follow(app, &o.host)
		o.host.input = overlay_input
		o.host.close_asked = proc(h: ^host.Host) { (^App)(h.user).overlay.decision = .Cancel }
		o.host.after_input = 2
		app_wake_add(app, o.host.win)
	}
	f := app.desktop.frame
	r := &app.shared.r
	if o.tex != 0 && o.tex_size != {int(f.width), int(f.height)} {
		render.destroy_texture(r, o.tex)
		o.tex = 0
	}
	if o.tex == 0 {
		o.tex = render.create_texture_rgba(r, int(f.width), int(f.height), mips = false)
		o.tex_size = {int(f.width), int(f.height)}
	}
	if o.tex == 0 { return false }
	render.update_texture_rgba(r, o.tex, 0, 0, int(f.width), int(f.height), f.pixels, int(f.stride))
	o.decision = .None
	o.has_hover = false
	o.has_pointer = false
	o.picker = picker
	o.hover_grip = .None
	o.clicks = {}
	if !o.layer { o.out = overlay_output(app) }
	selection_reset(&o.sel, o.out)
	token := app_take_token(app)
	defer delete(token)
	if !o.layer { platform.set_fullscreen(o.host.win, true) }
	if !o.visible {
		host.host_show(&o.host)
		o.visible = true
	}
	if !o.layer { platform.raise_window_token(o.host.win, token) }   // (a layer surface has the keyboard from its showing)
	o.host.settle = max(o.host.settle, 3)
	return true
}

overlay_hide :: proc(app: ^App) {
	o := &app.overlay
	if !o.visible { return }
	host.host_hide(&o.host)
	o.visible = false
	o.decision = .None
}

// The texture goes with the renderer: before the windows close.
overlay_destroy :: proc(app: ^App) {
	o := &app.overlay
	if o.tex != 0 { render.destroy_texture(&app.shared.r, o.tex) }
	o.tex = 0
}

// Before the frame: the output the window covers now (its size is known once it is fullscreen).
overlay_prepare :: proc(app: ^App) {
	o := &app.overlay
	if o.layer { return }   // (a layer surface is on the output it was made for)
	out := overlay_output(app)
	if out != o.out {
		o.out = out
		if !o.sel.has_rect { selection_reset(&o.sel, out) } else { o.sel.bounds = out; selection_set(&o.sel, o.sel.rect) }
	}
}

// After the frame: what the user decided, acted on.
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
	case .Pick:
		o.decision = .None
		app_color_picked(app, o.picked, o.pick_rgb)
	}
}

// The output the pointer is on, as the capture session said; else the first. What a layer surface is made over.
@(private = "file")
overlay_pointer_output :: proc(app: ^App) -> Rect {
	outs := app.desktop.outputs
	if len(outs) == 0 { return {} }
	if app.desktop.has_pointer_output {
		for o in outs { if o.id == app.desktop.pointer_output { return o.rect } }
	}
	return outs[0].rect
}

// The output the window covers: from its size (logical) and the pointer, as output_for_window decides.
@(private = "file")
overlay_output :: proc(app: ^App) -> Rect {
	o := &app.overlay
	outs := app.desktop.outputs
	if len(outs) == 0 { return {app.desktop.frame.origin.x, app.desktop.frame.origin.y, 0, 0} }
	// (the compositor's word first: two monitors of the same size cannot be told apart by the window's)
	if name := platform.window_output_name(o.host.win); name != "" {
		for out in outs { if out.name == name { return out.rect } }
	}
	scale := overlay_scale(o)
	size := [2]i32{i32(math.round(f32(o.host.win.size.x) / scale)), i32(math.round(f32(o.host.win.size.y) / scale))}
	hint: Maybe(Point)
	if p, ok := pointer_on_desktop(); ok { hint = p }
	i := output_for_window(outs, size, nil, hint)
	return outs[max(i, 0)].rect
}

@(private = "file")
overlay_scale :: proc(o: ^Overlay) -> f32 {
	s := o.host.win != nil ? o.host.win.dpi_scale : 1
	return s > 0 ? s : 1
}

// A point of the window (its pixels) on the desktop (logical).
@(private = "file")
overlay_point :: proc(o: ^Overlay, p: [2]f32) -> Point {
	s := overlay_scale(o)
	return {o.out.x + i32(math.floor(p.x / s)), o.out.y + i32(math.floor(p.y / s))}
}

@(private = "file")
overlay_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	o := &app.overlay
	for e in events {
		#partial switch e.kind {
		case .Mouse_Move:
			o.pointer, o.has_pointer = overlay_point(o, e.pos), true
			selection_move(&o.sel, o.pointer)
		case .Mouse_Press:
			p := overlay_point(o, e.pos)
			o.pointer, o.has_pointer = p, true
			if e.button == .Right { overlay_escape(o); continue }
			if e.button != .Left { continue }
			if o.picker {
				overlay_pick(app, p, .Shift in e.mods)
				continue
			}
			// (a double click inside what is chosen takes it; its first click took the inside, and moved nothing)
			if click_double(&o.clicks, p, ui.now_ms()) && o.sel.has_rect && rect_contains(o.sel.rect, p) {
				selection_release(&o.sel, p)
				overlay_confirm(o, o.sel.rect)
				continue
			}
			if selection_take(&o.sel, p) != .None { continue }   // (a grip of what is chosen: moved or resized)
			selection_press(&o.sel, p)
		case .Mouse_Release:
			if e.button != .Left || o.picker { continue }
			p := overlay_point(o, e.pos)
			switch selection_release(&o.sel, p) {
			case .Click:
				if r, ok := frame_pick(app.desktop.windows, p, o.out, app.desktop.have_rects && app.settings.frame_windows); ok { overlay_confirm(o, r) }
			case .Rect:
				if app.settings.confirm_on_release { overlay_confirm(o, o.sel.rect) }
			case .Adjusted, .Held, .None:   // (adjusted: it stays chosen, Enter or a double click takes it)
			}
		case .Key_Press:
			if o.picker { overlay_picker_key(app, e) } else { overlay_key(o, e) }
		}
	}
	// (the window framed under the pointer, while no rectangle is chosen or dragged; else the grip under it)
	o.has_hover = false
	o.hover_grip = .None
	if o.has_pointer && !o.picker && !o.sel.dragging {
		if o.sel.has_rect {
			o.hover_grip = selection_grip_at(&o.sel, o.pointer)
		} else {
			o.hover, o.has_hover = frame_pick(app.desktop.windows, o.pointer, o.out, app.desktop.have_rects && app.settings.frame_windows)
		}
	}
	return nil   // (the overlay's interface is its picture: nothing goes to widgets)
}

@(private = "file")
overlay_key :: proc(o: ^Overlay, e: platform.Event) {
	step: i32 = .Ctrl in e.mods ? NUDGE_FAST : 1
	d: Point
	#partial switch e.key {
	case .Escape: overlay_escape(o); return
	case .Return, .Space:
		overlay_confirm(o, o.sel.has_rect ? o.sel.rect : o.out)
		return
	case .Left:  d = {-step, 0}
	case .Right: d = {step, 0}
	case .Up:    d = {0, -step}
	case .Down:  d = {0, step}
	case: return
	}
	if .Shift in e.mods { selection_resize(&o.sel, d) } else { selection_nudge(&o.sel, d) }
}

// The colour picker's keys: Enter takes the colour under the point (Shift: as rgb()), the arrows move the point (the
// system's pointer stays: only the pixel read moves), Escape gives it up.
@(private = "file")
overlay_picker_key :: proc(app: ^App, e: platform.Event) {
	o := &app.overlay
	step: i32 = .Ctrl in e.mods ? NUDGE_FAST : 1
	d: Point
	#partial switch e.key {
	case .Escape: o.decision = .Cancel; return
	case .Return, .Space:
		if o.has_pointer { overlay_pick(app, o.pointer, .Shift in e.mods) }
		return
	case .Left:  d = {-step, 0}
	case .Right: d = {step, 0}
	case .Up:    d = {0, -step}
	case .Down:  d = {0, step}
	case: return
	}
	if !o.has_pointer { return }
	o.pointer = point_clamp(o.pointer + d, {o.out.x, o.out.y, o.out.w - 1, o.out.h - 1})
}

// The colour of the pixel at `p` taken (Pick), from the frozen picture: no capture, one pixel read.
@(private = "file")
overlay_pick :: proc(app: ^App, p: Point, rgb: bool) {
	o := &app.overlay
	c, ok := frame_pixel(app.desktop.frame, p)
	if !ok { return }
	o.picked, o.pick_rgb = c, rgb
	o.decision = .Pick
}

// The pointer's shape over the overlay: the grip it is on or holds, else a cross.
@(private = "file")
overlay_cursor :: proc(o: ^Overlay) -> platform.Cursor {
	if o.picker { return .Crosshair }
	g := o.hover_grip
	if o.sel.dragging { g = o.sel.grip }   // (a new rectangle being drawn: None, a cross)
	switch g {
	case .None:     return .Crosshair
	case .Move:     return .Move
	case .N, .S:    return .Resize_V
	case .E, .W:    return .Resize_H
	case .NW, .SE:  return .Resize_NWSE
	case .NE, .SW:  return .Resize_NESW
	}
	return .Crosshair
}

@(private = "file")
overlay_escape :: proc(o: ^Overlay) {
	if o.sel.has_rect || o.sel.dragging {
		selection_reset(&o.sel, o.out)
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
	handles:    bool,      // the grips' squares on what is chosen
	swatch:     [4]u8,     // the colour under the pointer (the picker), beside the label
	has_swatch: bool,
}

// Where the frozen picture is on the desktop.
@(private = "file")
Frame_Place :: struct { origin: [2]i32, scale: f32 }

@(private = "file")
overlay_build :: proc(h: ^host.Host, size: ui.Vec2) {
	app := (^App)(h.user)
	o := &app.overlay
	d := ui.frame_new(Overlay_Draw)
	d^ = {tex = o.tex, frame = {app.desktop.frame.origin, app.desktop.frame.scale}, out = o.out, win_scale = overlay_scale(o), dim = app.settings.dim,
		pointer = o.pointer, magnifier = app.settings.magnifier && o.has_pointer, font = app.shared.font, font_size = ui.font_size()}
	// (no widget takes the pointer here: the shape is asked of the state, which the host gives the window after the build)
	h.state.cursor_request = overlay_cursor(o)
	if o.picker {
		// (the colours as they are: no shade; the magnifier always, it is the picker's tool)
		d.dim, d.magnifier = 0, o.has_pointer
		if o.has_pointer {
			if c, ok := frame_pixel(app.desktop.frame, o.pointer); ok {
				d.swatch, d.has_swatch = c, true
				d.label = fmt.tprintf("%s   %d, %d", color_pick_text(c, false), o.pointer.x, o.pointer.y)
			}
		}
	} else {
		switch {
		case o.sel.has_rect:  d.lit, d.has_lit = o.sel.rect, true
		case o.has_hover:     d.lit, d.has_lit = o.hover, true
		}
		// (no squares while a new rectangle is drawn: its corner follows the pointer)
		d.handles = o.sel.has_rect && !(o.sel.dragging && o.sel.grip == .None)
		if d.has_lit { d.label = fmt.tprintf("%d x %d", d.lit.w, d.lit.h) } else if o.has_pointer { d.label = fmt.tprintf("%d, %d", o.pointer.x, o.pointer.y) }
	}
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
		if d.handles { overlay_handles(d, dc, l) }
	}
	if d.magnifier { overlay_magnifier(d, dc, win) }
}

// The grips of what is chosen: a square at each corner and at the middle of each edge.
@(private = "file")
overlay_handles :: proc(d: ^Overlay_Draw, dc: ^draw.Context, l: draw.Rect) {
	side := math.round(HANDLE_PX * d.win_scale)
	half := side / 2
	line := max(math.round(d.win_scale), 1)
	mid := (l.min + l.max) / 2
	at := [8][2]f32{
		l.min, {mid.x, l.min.y}, {l.max.x, l.min.y},
		{l.min.x, mid.y}, {l.max.x, mid.y},
		{l.min.x, l.max.y}, {mid.x, l.max.y}, l.max,
	}
	for c in at {
		r := draw.Rect{c - {half, half}, c - {half, half} + {side, side}}
		draw.rect(dc, r, {1, 1, 1, 1})
		draw.rect(dc, r, {0, 0, 0, 0.7}, 0, line)
	}
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
		strip := draw.Rect{{dst.min.x, dst.max.y}, {dst.max.x, dst.max.y + fs * 1.6}}
		draw.rect(dc, strip, {0, 0, 0, 0.8})
		x := dst.min.x + fs * 0.5
		if d.has_swatch {
			// (the colour taken, as a square before its words)
			sw := draw.Rect{{x, strip.min.y + fs * 0.3}, {x + fs, strip.min.y + fs * 1.3}}
			c := d.swatch
			draw.rect(dc, sw, draw.srgb(f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255))   // (a pixel's values are sRGB)
			draw.rect(dc, sw, {1, 1, 1, 0.8}, 0, max(math.round(s), 1))
			x += fs * 1.5
		}
		draw.text(dc, d.font, fs, {x, dst.max.y + fs * 1.15}, {1, 1, 1, 1}, d.label)
	}
}
