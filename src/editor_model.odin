package cliche

// The editor's model: pure, tested without a window (editor_model_test.odin). The editor's window (editor.odin) turns
// its input into the events below and draws what the model holds; nothing here knows a window, a renderer or a font.
//
//   the document   the picture's size, the shapes (points in the picture's pixels), the selection, the crop, the undo
//                  and redo steps (a gt:undo stack, each step a copy of the shapes' list and of the crop)
//   the view       where the picture is in the canvas and how large: fitted, or zoomed and panned
//   the tool       what a press on the canvas does; each tool keeps its own style (colour, width...)
//   the mode       the interaction: one state machine, one transition procedure (edit_step), as flow.odin's
//
//   Idle --press--> Drawing | Moving | Resizing | Panning | Cropping | Typing
//   Drawing, Moving, Resizing, Panning, Cropping --release--> Idle
//   Typing --text end, press--> Idle
//
// A gesture is one undo step: the document is copied when it starts and the copy goes on the undo stack when it ends,
// unless the gesture changed nothing (a click on a shape selects it and leaves no step).

import "core:math"
import "core:slice"
import "core:strings"
import undo "gt:undo"

Edit_Vec :: [2]f32

// A rectangle by its two corners (min <= max once normalized).
Edit_Box :: struct { min, max: Edit_Vec }

Edit_Tool :: enum u8 { Select, Rectangle, Ellipse, Arrow, Line, Pen, Text, Highlighter, Pixelate, Step, Crop }

Edit_Kind :: enum u8 {
	Rectangle,
	Ellipse,
	Arrow,
	Line,
	Pen,           // freehand: its points
	Text,
	Highlighter,   // a translucent marker over a rectangle
	Pixelate,      // hides what is under its rectangle
	Step,          // a filled circle with a number that counts up
}

// What the properties' bar offers for a kind.
Edit_Prop :: enum u8 { Color, Width, Shadow, Fill, Text_Size }
Edit_Props :: bit_set[Edit_Prop; u8]

EDIT_PROPS := [Edit_Kind]Edit_Props{
	.Rectangle   = {.Color, .Width, .Shadow, .Fill},
	.Ellipse     = {.Color, .Width, .Shadow, .Fill},
	.Arrow       = {.Color, .Width, .Shadow},
	.Line        = {.Color, .Width, .Shadow},
	.Pen         = {.Color, .Width, .Shadow},
	.Text        = {.Color, .Shadow, .Text_Size},
	.Highlighter = {.Color},
	.Pixelate    = {},
	.Step        = {.Color, .Shadow, .Text_Size},
}

// The look of a shape. Lengths are logical pixels: on a picture taken at 200 %, a 4 px stroke is 8 of its pixels.
Edit_Style :: struct {
	color:     u32,   // 0xRRGGBB, sRGB
	width:     f32,
	shadow:    f32,   // the shadow's softness, logical pixels (its blur; it falls a little less far): 0 none
	fill:      bool,
	text_size: f32,
}

// The swatches: red first, the default (ShareX's look: red reads on any screenshot).
EDIT_COLORS := [?]u32{0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF}
EDIT_WIDTH_MIN :: 1    // a stroke's width, logical pixels: the slider's ends
EDIT_WIDTH_MAX :: 40
EDIT_TEXT_SIZES := [?]f32{16, 24, 32, 48}
EDIT_SHADOW_MAX :: 20   // the shadow's slider's end, logical pixels

EDIT_STYLE_DEFAULT :: Edit_Style{color = 0xE53935, width = 4, shadow = 3, fill = false, text_size = 24}
EDIT_HIGHLIGHT_COLOR :: 0xFDD835   // (the yellow swatch)
EDIT_HIGHLIGHT_ALPHA :: 0.4

EDIT_HIT_PX       :: 6      // how far from a stroke a press still takes it, window pixels
EDIT_HANDLE_PX    :: 7      // how far from a handle's centre a press takes it, window pixels
EDIT_SMALL_PX     :: 4      // a shape drawn smaller than this on the screen was a click: it is dropped
EDIT_ZOOM_MIN     :: 0.05
EDIT_ZOOM_MAX     :: 16
EDIT_ZOOM_STEP    :: 1.25   // one notch of the wheel, one Ctrl+= or Ctrl+-
EDIT_WHEEL_PAN_PX :: 60     // window pixels a notch of the wheel pans
EDIT_FIT_MARGIN   :: 0.96   // the share of the canvas a fitted picture takes: its edge stays visible
EDIT_NUDGE_FAST   :: 10     // picture pixels a step with Shift
EDIT_DUPLICATE_PX :: 16     // logical pixels a copy lands from its original
EDIT_STEP_RADIUS  :: 0.8    // a step's radius, in its text size

Edit_Shape :: struct {
	kind:   Edit_Kind,
	// a box's two corners, or a line's two ends (a: where it starts). Text: its top left, then its bottom right as
	// measured. Step: its centre, twice.
	a, b:   Edit_Vec,
	points: [dynamic]Edit_Vec,   // Pen (owned)
	text:   string,              // Text (owned)
	number: int,                 // Step
	style:  Edit_Style,
}

// The shapes and the crop as they were (owned).
Edit_Snapshot :: struct {
	shapes:   []Edit_Shape,
	crop:     Edit_Box,
	has_crop: bool,
}

// The size of a text in the picture's pixels, at `size` picture pixels: the window's font measures it.
Edit_Measure :: proc(user: rawptr, text: string, size: f32) -> Edit_Vec

Edit_Doc :: struct {
	size:         Edit_Vec,   // the picture, pixels
	scale:        f32,        // the picture's pixels per logical pixel
	shapes:       [dynamic]Edit_Shape,   // drawn in order: the last one on top
	selected:     int,        // -1: none
	crop:         Edit_Box,   // what the picture keeps when it is done (has_crop), in its pixels
	has_crop:     bool,
	history:      undo.Stack(Edit_Snapshot),
	pending:      Edit_Snapshot,   // the document when the gesture began (has_pending)
	has_pending:  bool,
	measure:      Edit_Measure,
	measure_user: rawptr,
}

// Where the picture is shown. Window pixels: the canvas box's, the offset from its top left, the zoom.
Edit_View :: struct {
	canvas: Edit_Box,
	zoom:   f32,        // window pixels per picture pixel
	offset: Edit_Vec,   // the picture's top left, from the canvas' top left
	fit:    bool,       // the picture is fitted to the canvas at each frame (until a zoom or a pan)
}

Edit_Handle :: enum u8 { None, Top_Left, Top, Top_Right, Right, Bottom_Right, Bottom, Bottom_Left, Left, Start, End }
Edit_Handles :: bit_set[Edit_Handle; u16]

EDIT_BOX_HANDLES :: Edit_Handles{.Top_Left, .Top, .Top_Right, .Right, .Bottom_Right, .Bottom, .Bottom_Left, .Left}
EDIT_LINE_HANDLES :: Edit_Handles{.Start, .End}

// The interaction's states.
Edit_Idle     :: struct {}
Edit_Drawing  :: struct { index: int, start: Edit_Vec }                         // a new shape follows the pointer
Edit_Moving   :: struct { index: int, last: Edit_Vec }                          // picture pixels
Edit_Resizing :: struct { index: int, handle: Edit_Handle, start, a, b: Edit_Vec }   // the press and the shape as it was
Edit_Panning  :: struct { last: Edit_Vec }                                      // window pixels
Edit_Cropping :: struct { start: Edit_Vec }
Edit_Typing   :: struct { index: int, before: string, fresh: bool }   // before: the text as it was (owned); fresh: a new text

Edit_Mode :: union #no_nil { Edit_Idle, Edit_Drawing, Edit_Moving, Edit_Resizing, Edit_Panning, Edit_Cropping, Edit_Typing }

Edit_Button :: enum u8 { Left, Middle, Right }

// The events, in window pixels. `pan`: Space is held (a left drag pans then).
Edit_Press    :: struct { at: Edit_Vec, button: Edit_Button, shift, pan, double: bool }
Edit_Move     :: struct { at: Edit_Vec, shift: bool }
Edit_Release  :: struct { at: Edit_Vec, button: Edit_Button, shift: bool }
Edit_Wheel    :: struct { at: Edit_Vec, delta: Edit_Vec, zoom, sideways: bool }   // delta: notches, +y away from the top
Edit_Typed    :: struct { text: string }   // the text field's text now (not kept)
Edit_Type_End :: struct { keep: bool }     // Enter or a press elsewhere keep the text; Escape gives back the one before

Edit_Event :: union { Edit_Press, Edit_Move, Edit_Release, Edit_Wheel, Edit_Typed, Edit_Type_End }

Edit_Model :: struct {
	doc:    Edit_Doc,
	view:   Edit_View,
	mode:   Edit_Mode,
	tool:   Edit_Tool,
	styles: [Edit_Tool]Edit_Style,   // each tool's own, for its next shape
	typing: u32,   // counts the starts of Typing: the window puts the shape's text in its field at a new one
	// the last undo step was a width set on this shape (its index + 1; 0: none), and the stack was this long after it:
	// the widths a slider runs through are one step, not one a frame
	width_run, width_run_undo: int,
}

edit_model_init :: proc(m: ^Edit_Model, size: [2]int, scale: f32, measure: Edit_Measure, measure_user: rawptr) {
	m.doc = {size = {f32(size.x), f32(size.y)}, scale = scale > 0 ? scale : 1, selected = -1, measure = measure, measure_user = measure_user}
	m.view = {zoom = 1, fit = true}
	m.mode = Edit_Idle{}
	m.tool = .Arrow
	for t in Edit_Tool { m.styles[t] = EDIT_STYLE_DEFAULT }
	m.styles[.Highlighter] = {color = EDIT_HIGHLIGHT_COLOR, width = EDIT_STYLE_DEFAULT.width, text_size = EDIT_STYLE_DEFAULT.text_size}
	m.styles[.Pixelate].shadow = 0
}

edit_model_destroy :: proc(m: ^Edit_Model) {
	if t, typing := m.mode.(Edit_Typing); typing { delete(t.before) }
	m.mode = Edit_Idle{}
	shapes_free(m.doc.shapes[:])
	delete(m.doc.shapes)
	undo.destroy(&m.doc.history, snapshot_free)
	if m.doc.has_pending { snapshot_free(&m.doc.pending) }
	m.doc = {}
}

////////////////////////////////
// Geometry

edit_box_of :: proc(a, b: Edit_Vec) -> Edit_Box {
	return {{min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}}
}

edit_box_size :: proc(r: Edit_Box) -> Edit_Vec { return r.max - r.min }

edit_box_contains :: proc(r: Edit_Box, p: Edit_Vec) -> bool {
	return p.x >= r.min.x && p.x <= r.max.x && p.y >= r.min.y && p.y <= r.max.y
}

edit_box_pad :: proc(r: Edit_Box, d: f32) -> Edit_Box { return {r.min - d, r.max + d} }

@(private = "file")
length :: proc(v: Edit_Vec) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

// The distance from `p` to the segment a-b.
@(private = "file")
segment_distance :: proc(p, a, b: Edit_Vec) -> f32 {
	d := b - a
	l2 := d.x * d.x + d.y * d.y
	if l2 == 0 { return length(p - a) }
	t := clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0, 1)
	return length(p - (a + d * t))
}

// `p` held to a square from `a` (Shift: a square, a circle).
edit_square :: proc(a, p: Edit_Vec) -> Edit_Vec {
	d := p - a
	side := max(abs(d.x), abs(d.y))
	return a + {d.x < 0 ? -side : side, d.y < 0 ? -side : side}
}

// `p` turned around `a` to the nearest multiple of 45° (Shift: a line or an arrow straight or diagonal).
edit_snap_45 :: proc(a, p: Edit_Vec) -> Edit_Vec {
	d := p - a
	l := length(d)
	if l == 0 { return p }
	step := f32(math.PI / 4)
	angle := math.round(math.atan2(d.y, d.x) / step) * step
	return a + {math.cos(angle), math.sin(angle)} * l
}

////////////////////////////////
// The view

edit_to_picture :: proc(v: Edit_View, p: Edit_Vec) -> Edit_Vec { return (p - v.canvas.min - v.offset) / v.zoom }
edit_to_window :: proc(v: Edit_View, p: Edit_Vec) -> Edit_Vec { return p * v.zoom + v.canvas.min + v.offset }

// The canvas box this frame (window pixels): a fitted picture is fitted again to it.
edit_view_place :: proc(m: ^Edit_Model, canvas: Edit_Box) {
	m.view.canvas = canvas
	if m.view.fit { edit_view_fit(m) }
}

// The whole picture in the canvas, centred, never enlarged past its own pixels.
edit_view_fit :: proc(m: ^Edit_Model) {
	v := &m.view
	c := edit_box_size(v.canvas)
	s := m.doc.size
	v.fit = true
	if s.x <= 0 || s.y <= 0 || c.x <= 0 || c.y <= 0 { return }
	v.zoom = clamp(min(c.x * EDIT_FIT_MARGIN / s.x, c.y * EDIT_FIT_MARGIN / s.y, 1), EDIT_ZOOM_MIN, EDIT_ZOOM_MAX)
	v.offset = (c - s * v.zoom) * 0.5
}

// Zooms by `factor`, keeping the picture's point under `at` (window pixels) where it is.
edit_view_zoom :: proc(m: ^Edit_Model, factor: f32, at: Edit_Vec) {
	v := &m.view
	under := edit_to_picture(v^, at)
	v.zoom = clamp(v.zoom * factor, EDIT_ZOOM_MIN, EDIT_ZOOM_MAX)
	v.offset = at - v.canvas.min - under * v.zoom
	v.fit = false
}

// Zooms around the canvas' centre (Ctrl+=, Ctrl+-).
edit_view_zoom_centre :: proc(m: ^Edit_Model, factor: f32) {
	edit_view_zoom(m, factor, (m.view.canvas.min + m.view.canvas.max) * 0.5)
}

////////////////////////////////
// Shapes

@(private = "file")
shape_clone :: proc(s: Edit_Shape) -> Edit_Shape {
	out := s
	out.points = nil
	if len(s.points) > 0 {
		out.points = make([dynamic]Edit_Vec, len(s.points))
		copy(out.points[:], s.points[:])
	}
	out.text = strings.clone(s.text)
	return out
}

@(private = "file")
shape_free :: proc(s: ^Edit_Shape) {
	delete(s.points)
	delete(s.text)
	s.points, s.text = nil, ""
}

@(private = "file")
shapes_free :: proc(list: []Edit_Shape) { for &s in list { shape_free(&s) } }

@(private = "file")
shapes_equal :: proc(x, y: []Edit_Shape) -> bool {
	if len(x) != len(y) { return false }
	for i in 0 ..< len(x) {
		p, q := x[i], y[i]
		if p.kind != q.kind || p.a != q.a || p.b != q.b || p.number != q.number || p.style != q.style || p.text != q.text { return false }
		if !slice.equal(p.points[:], q.points[:]) { return false }
	}
	return true
}

// The box a shape covers, without its stroke's width.
edit_shape_box :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> Edit_Box {
	#partial switch s.kind {
	case .Pen:
		if len(s.points) == 0 { return {s.a, s.a} }
		r := Edit_Box{s.points[0], s.points[0]}
		for p in s.points[1:] { r = {{min(r.min.x, p.x), min(r.min.y, p.y)}, {max(r.max.x, p.x), max(r.max.y, p.y)}} }
		return r
	case .Step:
		r := edit_step_radius(doc, s)
		return {s.a - r, s.a + r}
	}
	return edit_box_of(s.a, s.b)
}

// A stroke's width in the picture's pixels.
edit_stroke_px :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return s.style.width * doc.scale }

edit_text_px :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return s.style.text_size * doc.scale }

edit_step_radius :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return edit_text_px(doc, s) * EDIT_STEP_RADIUS }

// The number the next step takes: one past the highest (a step deleted last is given again).
edit_step_next :: proc(doc: ^Edit_Doc) -> int {
	n := 0
	for s in doc.shapes { if s.kind == .Step { n = max(n, s.number) } }
	return n + 1
}

// A text's box from its measure: its top left stays.
@(private = "file")
text_measure :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) {
	size := Edit_Vec{1, edit_text_px(doc, s)}
	if doc.measure != nil { size = doc.measure(doc.measure_user, s.text, edit_text_px(doc, s)) }
	s.b = s.a + {max(size.x, 1), max(size.y, 1)}
}

// Whether `p` (picture pixels) touches the shape, `tolerance` picture pixels around its stroke.
edit_shape_hit :: proc(doc: ^Edit_Doc, s: ^Edit_Shape, p: Edit_Vec, tolerance: f32) -> bool {
	half := edit_stroke_px(doc, s) * 0.5 + tolerance
	switch s.kind {
	case .Rectangle:
		r := edit_box_of(s.a, s.b)
		if s.style.fill { return edit_box_contains(edit_box_pad(r, half), p) }
		return edit_box_contains(edit_box_pad(r, half), p) && !edit_box_contains(edit_box_pad(r, -half), p)
	case .Ellipse:
		r := edit_box_of(s.a, s.b)
		c := (r.min + r.max) * 0.5
		radii := edit_box_size(r) * 0.5
		if radii.x < 1 || radii.y < 1 { return segment_distance(p, r.min, r.max) <= half }
		d := length((p - c) / radii)
		if s.style.fill { return d <= 1 + half / min(radii.x, radii.y) }
		return abs(d - 1) * min(radii.x, radii.y) <= half
	case .Arrow, .Line:
		return segment_distance(p, s.a, s.b) <= half
	case .Pen:
		if len(s.points) == 1 { return length(p - s.points[0]) <= half }
		for i in 1 ..< len(s.points) { if segment_distance(p, s.points[i - 1], s.points[i]) <= half { return true } }
		return false
	case .Text, .Highlighter, .Pixelate:
		return edit_box_contains(edit_box_pad(edit_box_of(s.a, s.b), tolerance), p)
	case .Step:
		return length(p - s.a) <= edit_step_radius(doc, s) + tolerance
	}
	return false
}

// The topmost shape under `p` (picture pixels), or -1.
edit_hit :: proc(doc: ^Edit_Doc, p: Edit_Vec, tolerance: f32) -> int {
	#reverse for &s, i in doc.shapes[:] { if edit_shape_hit(doc, &s, p, tolerance) { return i } }
	return -1
}

// The handles a shape has, and where each is (picture pixels).
edit_handles :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> (at: [Edit_Handle]Edit_Vec, has: Edit_Handles) {
	#partial switch s.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate:
		r := edit_box_of(s.a, s.b)
		c := (r.min + r.max) * 0.5
		at[.Top_Left], at[.Top], at[.Top_Right] = r.min, {c.x, r.min.y}, {r.max.x, r.min.y}
		at[.Right], at[.Bottom_Right], at[.Bottom] = {r.max.x, c.y}, r.max, {c.x, r.max.y}
		at[.Bottom_Left], at[.Left] = {r.min.x, r.max.y}, {r.min.x, c.y}
		has = EDIT_BOX_HANDLES
	case .Arrow, .Line:
		at[.Start], at[.End] = s.a, s.b
		has = EDIT_LINE_HANDLES
	}
	return
}

// The handle of the selected shape under `p` (picture pixels), within `tolerance`.
edit_handle_hit :: proc(doc: ^Edit_Doc, p: Edit_Vec, tolerance: f32) -> Edit_Handle {
	if doc.selected < 0 || doc.selected >= len(doc.shapes) { return .None }
	at, has := edit_handles(doc, &doc.shapes[doc.selected])
	for h in Edit_Handle {
		if h in has && abs(p.x - at[h].x) <= tolerance && abs(p.y - at[h].y) <= tolerance { return h }
	}
	return .None
}

@(private = "file")
shape_translate :: proc(s: ^Edit_Shape, d: Edit_Vec) {
	s.a += d
	s.b += d
	for &p in s.points { p += d }
}

// The shape as it was (`a`, `b`) with `handle` moved by `d`. Shift keeps a line or an arrow straight or diagonal.
@(private = "file")
shape_resize :: proc(s: ^Edit_Shape, handle: Edit_Handle, a, b, d: Edit_Vec, shift: bool) {
	if handle == .Start || handle == .End {
		s.a, s.b = a, b
		if handle == .Start { s.a = shift ? edit_snap_45(b, a + d) : a + d } else { s.b = shift ? edit_snap_45(a, b + d) : b + d }
		return
	}
	r := edit_box_of(a, b)
	#partial switch handle {
	case .Top_Left:     r.min += d
	case .Top:          r.min.y += d.y
	case .Top_Right:    r.min.y += d.y; r.max.x += d.x
	case .Right:        r.max.x += d.x
	case .Bottom_Right: r.max += d
	case .Bottom:       r.max.y += d.y
	case .Bottom_Left:  r.max.y += d.y; r.min.x += d.x
	case .Left:         r.min.x += d.x
	}
	// (dragged past the other side: the box turns over, as it does in every editor)
	s.a, s.b = r.min, r.max
}

////////////////////////////////
// Undo and redo

@(private = "file")
snapshot_take :: proc(doc: ^Edit_Doc) -> Edit_Snapshot {
	out := Edit_Snapshot{shapes = make([]Edit_Shape, len(doc.shapes)), crop = doc.crop, has_crop = doc.has_crop}
	for s, i in doc.shapes { out.shapes[i] = shape_clone(s) }
	return out
}

@(private = "file")
snapshot_free :: proc(s: ^Edit_Snapshot) {
	shapes_free(s.shapes)
	delete(s.shapes)
	s^ = {}
}

// The document becomes `s` (taken: its shapes are the document's now).
@(private = "file")
snapshot_restore :: proc(doc: ^Edit_Doc, s: Edit_Snapshot) {
	shapes_free(doc.shapes[:])
	clear(&doc.shapes)
	append(&doc.shapes, ..s.shapes)
	delete(s.shapes)
	doc.crop, doc.has_crop = s.crop, s.has_crop
	doc.selected = -1
}

// A change begins: the document as it is now is kept, for the undo stack.
@(private = "file")
change_begin :: proc(doc: ^Edit_Doc) {
	if doc.has_pending { snapshot_free(&doc.pending) }
	doc.pending, doc.has_pending = snapshot_take(doc), true
}

// The change ends: what was kept goes on the undo stack, unless nothing changed.
@(private = "file")
change_end :: proc(doc: ^Edit_Doc) {
	if !doc.has_pending { return }
	doc.has_pending = false
	p := doc.pending
	doc.pending = {}
	if shapes_equal(p.shapes, doc.shapes[:]) && p.crop == doc.crop && p.has_crop == doc.has_crop {
		snapshot_free(&p)
		return
	}
	undo.push(&doc.history, p, 0, snapshot_free)
}

// Whether anything was changed since the picture came (the window asks before it closes).
edit_changed :: proc(m: ^Edit_Model) -> bool { return undo.can_undo(&m.doc.history) }

edit_can_undo :: proc(m: ^Edit_Model) -> bool { return undo.can_undo(&m.doc.history) && edit_idle(m) }
edit_can_redo :: proc(m: ^Edit_Model) -> bool { return undo.can_redo(&m.doc.history) && edit_idle(m) }

edit_undo :: proc(m: ^Edit_Model) -> bool {
	if !edit_can_undo(m) { return false }
	back, _ := undo.undo(&m.doc.history, snapshot_take(&m.doc))
	snapshot_restore(&m.doc, back)
	return true
}

edit_redo :: proc(m: ^Edit_Model) -> bool {
	if !edit_can_redo(m) { return false }
	again, _ := undo.redo(&m.doc.history, snapshot_take(&m.doc))
	snapshot_restore(&m.doc, again)
	return true
}

////////////////////////////////
// Operations on the document (in Idle: a gesture going on has the document)

edit_idle :: proc(m: ^Edit_Model) -> bool {
	_, idle := m.mode.(Edit_Idle)
	return idle
}

edit_has_selection :: proc(m: ^Edit_Model) -> bool { return m.doc.selected >= 0 && m.doc.selected < len(m.doc.shapes) }

edit_selected_shape :: proc(m: ^Edit_Model) -> ^Edit_Shape {
	return edit_has_selection(m) ? &m.doc.shapes[m.doc.selected] : nil
}

// Adds a shape (taken: its points and text are the document's now) on top, selected; one undo step.
edit_add :: proc(m: ^Edit_Model, s: Edit_Shape) -> int {
	change_begin(&m.doc)
	append(&m.doc.shapes, s)
	i := len(m.doc.shapes) - 1
	if s.kind == .Text { text_measure(&m.doc, &m.doc.shapes[i]) }
	m.doc.selected = i
	change_end(&m.doc)
	return i
}

edit_delete :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	change_begin(&m.doc)
	shape_free(&m.doc.shapes[m.doc.selected])
	ordered_remove(&m.doc.shapes, m.doc.selected)
	m.doc.selected = -1
	change_end(&m.doc)
	return true
}

// A copy of the selected shape, a little below and right of it, on top and selected. A step's copy takes the next number.
edit_duplicate :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	c := shape_clone(m.doc.shapes[m.doc.selected])
	shape_translate(&c, Edit_Vec{1, 1} * (EDIT_DUPLICATE_PX * m.doc.scale))
	if c.kind == .Step { c.number = edit_step_next(&m.doc) }
	edit_add(m, c)
	return true
}

// Moves the selected shape by `d` picture pixels (the arrow keys).
edit_nudge :: proc(m: ^Edit_Model, d: Edit_Vec) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	change_begin(&m.doc)
	shape_translate(&m.doc.shapes[m.doc.selected], d)
	change_end(&m.doc)
	return true
}

edit_deselect :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || m.doc.selected < 0 { return false }
	m.doc.selected = -1
	return true
}

// A tool chosen: a drawing tool lets go of the selection (its properties are the tool's then).
edit_tool_set :: proc(m: ^Edit_Model, t: Edit_Tool) {
	m.tool = t
	if t != .Select && edit_idle(m) { m.doc.selected = -1 }
}

// The kind of shape a tool draws (ok false: Select, Crop).
edit_tool_kind :: proc(t: Edit_Tool) -> (k: Edit_Kind, ok: bool) {
	switch t {
	case .Select, .Crop: return
	case .Rectangle:     return .Rectangle, true
	case .Ellipse:       return .Ellipse, true
	case .Arrow:         return .Arrow, true
	case .Line:          return .Line, true
	case .Pen:           return .Pen, true
	case .Text:          return .Text, true
	case .Highlighter:   return .Highlighter, true
	case .Pixelate:      return .Pixelate, true
	case .Step:          return .Step, true
	}
	return
}

edit_kind_tool :: proc(k: Edit_Kind) -> Edit_Tool {
	switch k {
	case .Rectangle:   return .Rectangle
	case .Ellipse:     return .Ellipse
	case .Arrow:       return .Arrow
	case .Line:        return .Line
	case .Pen:         return .Pen
	case .Text:        return .Text
	case .Highlighter: return .Highlighter
	case .Pixelate:    return .Pixelate
	case .Step:        return .Step
	}
	return .Select
}

// The style the properties' bar shows, and which of its properties apply: the selection's, else the tool's.
edit_style_shown :: proc(m: ^Edit_Model) -> (style: Edit_Style, props: Edit_Props) {
	if s := edit_selected_shape(m); s != nil { return s.style, EDIT_PROPS[s.kind] }
	if k, ok := edit_tool_kind(m.tool); ok { return m.styles[m.tool], EDIT_PROPS[k] }
	return EDIT_STYLE_DEFAULT, {}
}

// A property set: on the selection (one undo step) and on the tool that draws its kind, else on the current tool.
edit_style_set :: proc(m: ^Edit_Model, style: Edit_Style) -> bool {
	if !edit_idle(m) { return false }
	if s := edit_selected_shape(m); s != nil {
		if s.style == style { return false }
		width_only := style.width != s.style.width && edit_style_but_width(style, s.style)
		run := width_only && m.width_run == m.doc.selected + 1 && m.width_run_undo == len(m.doc.history.undo) && !undo.can_redo(&m.doc.history)
		if !run { change_begin(&m.doc) }
		s.style = style
		if s.kind == .Text { text_measure(&m.doc, s) }
		if !run { change_end(&m.doc) }
		m.width_run, m.width_run_undo = width_only ? m.doc.selected + 1 : 0, len(m.doc.history.undo)
		m.styles[edit_kind_tool(s.kind)] = style
		return true
	}
	if _, ok := edit_tool_kind(m.tool); !ok { return false }
	m.styles[m.tool] = style
	return true
}

// The two styles are the same but for their widths.
@(private = "file")
edit_style_but_width :: proc(a, b: Edit_Style) -> bool {
	a, b := a, b
	a.width, b.width = 0, 0
	return a == b
}

// The part of the picture that is kept, in whole pixels: the crop, else all of it.
edit_output_box :: proc(doc: ^Edit_Doc) -> (x, y, w, h: int) {
	if !doc.has_crop { return 0, 0, int(doc.size.x), int(doc.size.y) }
	x0 := clamp(int(math.round(doc.crop.min.x)), 0, int(doc.size.x))
	y0 := clamp(int(math.round(doc.crop.min.y)), 0, int(doc.size.y))
	x1 := clamp(int(math.round(doc.crop.max.x)), x0, int(doc.size.x))
	y1 := clamp(int(math.round(doc.crop.max.y)), y0, int(doc.size.y))
	if x1 - x0 < 1 || y1 - y0 < 1 { return 0, 0, int(doc.size.x), int(doc.size.y) }
	return x0, y0, x1 - x0, y1 - y0
}

// Takes the crop away (one undo step).
edit_crop_clear :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || !m.doc.has_crop { return false }
	change_begin(&m.doc)
	m.doc.has_crop = false
	m.doc.crop = {}
	change_end(&m.doc)
	return true
}

@(private = "file")
picture_clamp :: proc(doc: ^Edit_Doc, p: Edit_Vec) -> Edit_Vec {
	return {clamp(p.x, 0, doc.size.x), clamp(p.y, 0, doc.size.y)}
}

////////////////////////////////
// The interaction

// Applies an event. False: it means nothing in the current mode (a release with nothing pressed, a wheel during a drag).
edit_step :: proc(m: ^Edit_Model, e: Edit_Event) -> bool {
	doc := &m.doc
	switch &s in m.mode {
	case Edit_Idle:
		#partial switch v in e {
		case Edit_Press:  return idle_press(m, v)
		case Edit_Wheel:  return wheel(m, v)
		}
	case Edit_Drawing:
		#partial switch v in e {
		case Edit_Move:
			drawing_follow(m, s, edit_to_picture(m.view, v.at), v.shift)
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			drawing_follow(m, s, edit_to_picture(m.view, v.at), v.shift)
			sh := &doc.shapes[s.index]
			// (a press with no drag drew nothing worth keeping: a box or a line too small to see)
			r := edit_shape_box(doc, sh)
			small := max(r.max.x - r.min.x, r.max.y - r.min.y) * m.view.zoom < EDIT_SMALL_PX
			#partial switch sh.kind {
			case .Rectangle, .Ellipse, .Arrow, .Line, .Highlighter, .Pixelate:
				if small {
					shape_free(sh)
					ordered_remove(&doc.shapes, s.index)
					doc.selected = -1
				}
			}
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Moving:
		#partial switch v in e {
		case Edit_Move:
			p := edit_to_picture(m.view, v.at)
			shape_translate(&doc.shapes[s.index], p - s.last)
			s.last = p
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			p := edit_to_picture(m.view, v.at)
			shape_translate(&doc.shapes[s.index], p - s.last)
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Resizing:
		#partial switch v in e {
		case Edit_Move:
			shape_resize(&doc.shapes[s.index], s.handle, s.a, s.b, edit_to_picture(m.view, v.at) - s.start, v.shift)
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			shape_resize(&doc.shapes[s.index], s.handle, s.a, s.b, edit_to_picture(m.view, v.at) - s.start, v.shift)
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Panning:
		#partial switch v in e {
		case Edit_Move:
			m.view.offset += v.at - s.last
			s.last = v.at
			return true
		case Edit_Release:
			m.view.offset += v.at - s.last
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Cropping:
		#partial switch v in e {
		case Edit_Move:
			cropping_follow(m, s.start, edit_to_picture(m.view, v.at), v.shift)
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			cropping_follow(m, s.start, edit_to_picture(m.view, v.at), v.shift)
			r := edit_box_size(doc.crop) * m.view.zoom
			if r.x < EDIT_SMALL_PX || r.y < EDIT_SMALL_PX { doc.has_crop, doc.crop = false, Edit_Box{} }   // (a click: no crop)
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Typing:
		#partial switch v in e {
		case Edit_Typed:
			sh := &doc.shapes[s.index]
			if sh.text == v.text { return false }
			delete(sh.text)
			sh.text = strings.clone(v.text)
			text_measure(doc, sh)
			return true
		case Edit_Type_End:
			typing_end(m, s, v.keep)
			return true
		case Edit_Press:
			// (a press elsewhere ends the text, kept; it does nothing else: the next press draws)
			typing_end(m, s, true)
			return true
		case Edit_Wheel:
			return wheel(m, v)
		}
	}
	return false
}

@(private = "file")
idle_press :: proc(m: ^Edit_Model, v: Edit_Press) -> bool {
	doc := &m.doc
	if v.button == .Middle || (v.button == .Left && v.pan) {
		m.mode = Edit_Panning{last = v.at}
		m.view.fit = false
		return true
	}
	if v.button != .Left { return false }
	p := edit_to_picture(m.view, v.at)
	tolerance := EDIT_HIT_PX / m.view.zoom
	if m.tool == .Crop {
		change_begin(doc)
		start := picture_clamp(doc, p)
		m.mode = Edit_Cropping{start = start}
		doc.crop, doc.has_crop = Edit_Box{start, start}, true
		return true
	}
	// (the selected shape's handles first, with any tool: a shape just drawn is resized at once)
	if h := edit_handle_hit(doc, p, EDIT_HANDLE_PX / m.view.zoom); h != .None {
		sh := &doc.shapes[doc.selected]
		change_begin(doc)
		m.mode = Edit_Resizing{index = doc.selected, handle = h, start = p, a = sh.a, b = sh.b}
		return true
	}
	hit := edit_hit(doc, p, tolerance)
	if hit >= 0 && doc.shapes[hit].kind == .Text && (v.double || m.tool == .Text) {
		typing_start(m, hit, fresh = false)
		return true
	}
	// (Select takes any shape; a drawing tool takes the selected one, and draws over the others)
	if hit >= 0 && (m.tool == .Select || hit == doc.selected) {
		doc.selected = hit
		change_begin(doc)
		m.mode = Edit_Moving{index = hit, last = p}
		return true
	}
	kind, draws := edit_tool_kind(m.tool)
	if !draws {
		doc.selected = -1
		return true
	}
	change_begin(doc)
	sh := Edit_Shape{kind = kind, a = p, b = p, style = m.styles[m.tool]}
	#partial switch kind {
	case .Pen:  append(&sh.points, p)
	case .Step: sh.number = edit_step_next(doc)
	}
	append(&doc.shapes, sh)
	i := len(doc.shapes) - 1
	doc.selected = i
	if kind == .Text {
		text_measure(doc, &doc.shapes[i])
		typing_start(m, i, fresh = true)
		return true
	}
	m.mode = Edit_Drawing{index = i, start = p}
	return true
}

@(private = "file")
drawing_follow :: proc(m: ^Edit_Model, s: Edit_Drawing, p: Edit_Vec, shift: bool) {
	sh := &m.doc.shapes[s.index]
	#partial switch sh.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate:
		sh.b = shift ? edit_square(sh.a, p) : p
	case .Arrow, .Line:
		sh.b = shift ? edit_snap_45(sh.a, p) : p
	case .Pen:
		// (a point only where the pointer went far enough: a held mouse adds none)
		last := sh.points[len(sh.points) - 1]
		if length(p - last) * m.view.zoom >= 1 { append(&sh.points, p) }
		sh.b = p
	case .Step:
		sh.a, sh.b = p, p
	}
}

@(private = "file")
cropping_follow :: proc(m: ^Edit_Model, start, p: Edit_Vec, shift: bool) {
	q := picture_clamp(&m.doc, shift ? edit_square(start, p) : p)
	m.doc.crop = edit_box_of(start, q)
	m.doc.has_crop = true
}

@(private = "file")
wheel :: proc(m: ^Edit_Model, v: Edit_Wheel) -> bool {
	if v.zoom {
		if v.delta.y == 0 { return false }
		edit_view_zoom(m, math.pow(f32(EDIT_ZOOM_STEP), -v.delta.y), v.at)
		return true
	}
	d := v.sideways ? Edit_Vec{v.delta.y, v.delta.x} : v.delta
	m.view.offset -= d * EDIT_WHEEL_PAN_PX
	m.view.fit = false
	return true
}

@(private = "file")
typing_start :: proc(m: ^Edit_Model, index: int, fresh: bool) {
	// (a new text was added inside a change already begun; an old one begins its change here)
	if !fresh { change_begin(&m.doc) }
	m.doc.selected = index
	m.mode = Edit_Typing{index = index, before = strings.clone(m.doc.shapes[index].text), fresh = fresh}
	m.typing += 1
}

@(private = "file")
typing_end :: proc(m: ^Edit_Model, s: Edit_Typing, keep: bool) {
	doc := &m.doc
	sh := &doc.shapes[s.index]
	if !keep {
		delete(sh.text)
		sh.text = strings.clone(s.before)
		text_measure(doc, sh)
	}
	// (a text left empty is no text)
	if sh.text == "" {
		shape_free(sh)
		ordered_remove(&doc.shapes, s.index)
		doc.selected = -1
	} else {
		doc.selected = s.index
	}
	delete(s.before)
	change_end(doc)
	m.mode = Edit_Idle{}
}
