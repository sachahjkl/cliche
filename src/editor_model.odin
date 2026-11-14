package cliche

// The editor's model: pure, tested without a window (editor_model_test.odin). The editor's window (editor.odin) turns
// its input into the events below and draws what the model holds; nothing here knows a window, a renderer or a font.
//
//   the document   the picture's size, the shapes (points in the picture's pixels), the selection, the crop, what was
//                  done to the picture itself (Edit_Doc.ops), the undo and redo steps (a gt:undo stack, each step a
//                  copy of the shapes' list, the crop and the operations)
//   the view       where the picture is in the canvas and how large: fitted, or zoomed and panned
//   the tool       what a press on the canvas does; each tool keeps its own style (colour, width...)
//   the mode       the interaction: one state machine, one transition procedure (edit_step), as flow.odin's
//
//   Idle --press--> Drawing | Moving | Resizing | Panning | Cropping | Cutting | Selecting | Typing
//   Idle --Shift+press on a shape, Select--> Idle (the shape added to the selection, or taken from it)
//   Idle --right press on a shape--> Idle (the shape selected: the window opens its menu)
//   Drawing (a balloon) --release--> Typing (its text: the same undo step)
//   Drawing, Moving, Resizing, Panning, Cropping, Cutting, Selecting --release--> Idle
//   Typing --text end, press--> Idle
//
// A gesture is one undo step: the document is copied when it starts and the copy goes on the undo stack when it ends,
// unless the gesture changed nothing (a click on a shape selects it and leaves no step).
//
// The selection is a flag on each shape (Edit_Shape.picked: it moves with the shape when the order changes), and one of
// the shapes picked is the one whose style the bar shows (Edit_Doc.selected). A move, a delete, the order and a style
// apply to every shape picked; the handles show when one shape is.
//
// The picture changes too (turned, mirrored, resized, given margins, a band cut out): the document keeps those
// operations in order (Edit_Doc.ops), and the window makes the picture from the one taken through all of them, on the
// chores (edit_picture_make). An operation is an undo step as a gesture is: the shapes go where the picture takes their
// points, and an undo takes the operation off the list.

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import undo "gt:undo"

Edit_Vec :: [2]f32

// A rectangle by its two corners (min <= max once normalized).
Edit_Box :: struct { min, max: Edit_Vec }

Edit_Tool :: enum u8 { Select, Rectangle, Ellipse, Arrow, Line, Pen, Text, Balloon, Highlighter, Pixelate, Blur, Eraser, Magnify, Step, Crop, Cut_Out }

Edit_Kind :: enum u8 {
	Rectangle,
	Ellipse,
	Arrow,
	Line,
	Pen,           // freehand: its points (with a head: a freehand arrow)
	Text,
	Balloon,       // a rounded box with a tail (its tip: Edit_Shape.c), a text inside
	Highlighter,   // a translucent marker over a rectangle
	Pixelate,      // hides what is under its rectangle behind a mosaic
	Blur,          // hides what is under its rectangle behind a blurred copy of the picture
	Eraser,        // hides what is under its rectangle behind the colour around it (Edit_Shape.sample)
	Magnify,       // the picture under its box, larger (Edit_Style.zoom), in a circle or a rectangle
	Step,          // a filled circle with a number that counts up
	Image,         // a picture on the picture: the window holds its pixels (Edit_Shape.image names them)
	Cursor,        // a mouse pointer, drawn in its box
	Sticker,       // an emoji (Edit_Shape.text), drawn from the font
}

// What the properties' bar offers for a kind. (In the bar's order: what folds last first.)
Edit_Prop :: enum u8 { Color, Fill, Width, Heads, Dash, Radius, Text_Size, Bold, Text_Look, Step_Format, Step_Number, Zoom, Lens, Blur_Radius, Pixel_Size, Shadow }
Edit_Props :: bit_set[Edit_Prop; u32]

EDIT_PROPS := [Edit_Kind]Edit_Props{
	.Rectangle   = {.Color, .Width, .Shadow, .Fill, .Dash, .Radius},
	.Ellipse     = {.Color, .Width, .Shadow, .Fill, .Dash},
	.Arrow       = {.Color, .Width, .Shadow, .Dash, .Heads},
	.Line        = {.Color, .Width, .Shadow, .Dash},
	.Pen         = {.Color, .Width, .Shadow, .Dash, .Heads},
	.Text        = {.Color, .Shadow, .Text_Size, .Fill, .Text_Look, .Bold},
	.Balloon     = {.Color, .Width, .Shadow, .Fill, .Dash, .Text_Size, .Bold},
	.Highlighter = {.Color},
	.Pixelate    = {.Pixel_Size},
	.Blur        = {.Blur_Radius},
	.Eraser      = {},
	.Magnify     = {.Color, .Width, .Shadow, .Dash, .Zoom, .Lens},
	.Step        = {.Color, .Shadow, .Text_Size, .Fill, .Step_Format, .Step_Number},
	.Image       = {.Shadow},
	.Cursor      = {.Shadow},
	.Sticker     = {.Shadow, .Text_Size},
}

// How a text shows on the picture: its letters alone, the letters with an outline, or the letters on a box.
Edit_Text_Look :: enum u8 { Plain, Outline, Background }

// How a step writes its number: 1, 2, 3; a, b, c; A, B, C; i, ii, iii.
Edit_Step_Format :: enum u8 { Number, Lower, Upper, Roman }

// How a stroke is drawn: whole, in dashes, in dots.
Edit_Dash :: enum u8 { Solid, Dashed, Dotted }

// Where an arrow (or a drawing) has its heads.
Edit_Heads :: enum u8 { None, End, Start, Both }

// The shape of a magnifier.
Edit_Lens :: enum u8 { Circle, Rectangle }

// The look of a shape. Lengths are logical pixels: on a picture taken at 200 %, a 4 px stroke is 8 of its pixels.
Edit_Style :: struct {
	color:       u32,   // 0xRRGGBB, sRGB
	// 0xAARRGGBB, sRGB: a box's or an ellipse's inside, a step's disc, a text's outline or box, a balloon's inside.
	// Alpha 0: none (a text's outline or box then takes black or white, whichever stands out from its letters)
	fill_color:  u32,
	width:       f32,
	shadow:      f32,   // the shadow's softness, logical pixels (its blur; it falls a little less far): 0 none
	text_size:   f32,
	text_look:   Edit_Text_Look,
	bold:        bool,
	step_format: Edit_Step_Format,
	blur_radius: f32,   // Blur: logical pixels
	pixel_size:  f32,   // Pixelate: a cell's side, logical pixels
	dash:        Edit_Dash,
	radius:      f32,   // Rectangle: its corners, logical pixels
	heads:       Edit_Heads,
	zoom:        f32,   // Magnify: how much larger
	lens:        Edit_Lens,
}

// The swatches: red first, the default (ShareX's look: red reads on any screenshot).
EDIT_COLORS := [?]u32{0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF}
EDIT_OPAQUE :: u32(0xFF000000)   // the alpha of a fill colour that is there
EDIT_WIDTH_MIN :: 1    // a stroke's width, logical pixels: the slider's ends
EDIT_WIDTH_MAX :: 40
EDIT_RADIUS_MAX :: 60  // a rectangle's corners, logical pixels: the slider's end
EDIT_TEXT_SIZES := [?]f32{16, 24, 32, 48}
EDIT_TEXT_SIZE_MIN :: 6     // what the scale handle can make of a text or a step, logical pixels
EDIT_TEXT_SIZE_MAX :: 400
EDIT_SHADOW_MAX :: 20   // the shadow's slider's end, logical pixels
// The choices of Blur's radius and Pixelate's cell: a few, each a blurred copy or a mosaic made once per picture
EDIT_BLUR_RADII := [?]f32{4, 8, 16, 32}
EDIT_PIXEL_SIZES := [?]f32{6, 12, 24, 48}
EDIT_MAGNIFY_ZOOMS := [?]f32{1.5, 2, 3, 4}

EDIT_STYLE_DEFAULT :: Edit_Style{color = 0xE53935, width = 4, shadow = 3, text_size = 24, blur_radius = 8, pixel_size = 12, heads = .End, zoom = 2}
EDIT_HIGHLIGHT_COLOR :: 0xFDD835   // (the yellow swatch)
EDIT_HIGHLIGHT_ALPHA :: 0.4
// A balloon's own: dark words and a dark edge on a white box, as a comic's
EDIT_BALLOON_STYLE :: Edit_Style{color = 0x000000, fill_color = EDIT_OPAQUE | 0xFFFFFF, width = 2, shadow = 3, text_size = 24, blur_radius = 8, pixel_size = 12, heads = .End, zoom = 2}

EDIT_HIT_PX       :: 6      // how far from a stroke a press still takes it, window pixels
EDIT_HANDLE_PX    :: 7      // how far from a handle's centre a press takes it, window pixels
EDIT_SMALL_PX     :: 4      // a shape drawn smaller than this on the screen was a click: it is dropped
EDIT_ZOOM_MIN     :: 0.05
EDIT_ZOOM_MAX     :: 16
EDIT_ZOOM_STEP    :: 1.25   // one notch of the wheel, one Ctrl+= or Ctrl+-
EDIT_ZOOMS        := [?]f32{0.5, 1, 2, 4}   // the zoom menu's steps (with "fit")
EDIT_WHEEL_PAN_PX :: 60     // window pixels a notch of the wheel pans
EDIT_FIT_MARGIN   :: 0.96   // the share of the canvas a fitted picture takes: its edge stays visible
EDIT_NUDGE_FAST   :: 10     // picture pixels a step with Shift
EDIT_DUPLICATE_PX :: 16     // logical pixels a copy lands from its original
EDIT_STEP_RADIUS  :: 0.8    // a step's radius, in its text size
EDIT_TEXT_OUTLINE :: 0.16   // a text's outline, in its text size (half of it shows: the letters cover the rest)
EDIT_TEXT_BOX_PAD :: 0.25   // the room around a text on a box, in its text size
EDIT_BALLOON_PAD  :: 0.5    // the room around a balloon's text, in its text size
EDIT_BALLOON_TAIL :: 16     // the least a new balloon's tail reaches below its box, logical pixels
EDIT_PASTE_FIT    :: 0.9    // a pasted picture larger than this share of the picture is made smaller to fit it
EDIT_SCALE_MIN    :: 0.02   // the least a pen's drawing or a pointer is scaled to, of its size
EDIT_STICKER_SIZE :: 48     // an emoji's size when it comes, logical pixels
EDIT_CURSOR_SIZE  :: Edit_Vec{23, 36}   // a pointer's box when it comes, logical pixels
EDIT_PICTURE_MAX  :: 16384  // the largest side a resize or margins can give the picture, pixels

// The emoji offered as stickers: what a screenshot is annotated with (a verdict, a warning, a pointer, a reaction).
EDIT_STICKERS := [?]string{"👍", "👎", "✅", "❌", "⚠️", "❗", "❓", "💡", "⭐", "❤️", "🔥", "🎉", "😀", "😂", "🤔", "👀", "👉", "🐛"}

Edit_Shape :: struct {
	kind:   Edit_Kind,
	// a box's two corners, or a line's two ends (a: where it starts). Text, Sticker: its top left, then its bottom right
	// as measured. Step: its centre, twice. Cursor: its top left, its bottom right.
	a, b:   Edit_Vec,
	c:      Edit_Vec,                // Balloon: its tail's tip
	points: [dynamic]Edit_Vec,   // Pen (owned)
	text:   string,              // Text, Balloon, Sticker (owned): its lines separated by "\n"
	number: int,                 // Step
	image:  u32,                 // Image: the window's picture of that id (never 0)
	sample: u32,                 // Eraser: the colour around its box, 0xAARRGGBB (alpha 0: not known yet)
	style:  Edit_Style,
	picked: bool,                // in the selection (not compared, not undone: an undo selects nothing)
}

// What is done to the picture itself. Each changes its size or where its pixels are; the shapes follow.
Edit_Op_Kind :: enum u8 { Rotate, Flip, Resize, Canvas, Cut }

Edit_Op :: struct {
	kind:    Edit_Op_Kind,
	turns:   int,      // Rotate: quarter turns clockwise (1, 2, 3)
	across:  bool,     // Flip: left to right (else top to bottom). Cut: a band of columns (else of rows)
	size:    [2]int,   // Resize: the picture's new size, pixels
	margins: [4]int,   // Canvas: left, top, right, bottom, pixels (0 or more)
	color:   u32,      // Canvas: the margins' colour, 0xAARRGGBB
	at:      int,      // Cut: where the band starts, pixels
	length:  int,      // Cut: the band's length, pixels
}

// The shapes, the crop and the picture's operations as they were (owned).
Edit_Snapshot :: struct {
	shapes:   []Edit_Shape,
	crop:     Edit_Box,
	has_crop: bool,
	ops:      []Edit_Op,
	size:     Edit_Vec,
	scale:    f32,
}

// The size of one line of text in the picture's pixels, at `size` picture pixels: the window's font measures it.
Edit_Measure :: proc(user: rawptr, text: string, size: f32, bold: bool) -> Edit_Vec

// The mean colour around a box of the picture as it is now (picture pixels), 0xAARRGGBB: the window reads its pixels.
Edit_Sample :: proc(user: rawptr, box: Edit_Box) -> u32

Edit_Doc :: struct {
	size:         Edit_Vec,   // the picture, pixels (after its operations)
	scale:        f32,        // the picture's pixels per logical pixel (a resize changes it: the strokes follow)
	shapes:       [dynamic]Edit_Shape,   // drawn in order: the last one on top
	selected:     int,        // the shape picked whose style the bar shows; -1: none picked
	picked_count: int,        // how many shapes are picked, and of which kinds (made again when the picks change)
	picked_kinds: bit_set[Edit_Kind; u32],
	crop:         Edit_Box,   // what the picture keeps when it is done (has_crop), in its pixels
	has_crop:     bool,
	ops:          [dynamic]Edit_Op,   // what was done to the picture taken, in order
	history:      undo.Stack(Edit_Snapshot),
	pending:      Edit_Snapshot,   // the document when the gesture began (has_pending)
	has_pending:  bool,
	step_start:   int,        // the least number the next step takes
	// counts the changes of the shapes kept (a gesture ended, an undo, a style): the window reads the shapes again
	// (which mosaics and blurred copies they need) only when it moved, not at each frame
	revision:     u64,
	measure:      Edit_Measure,
	sample:       Edit_Sample,
	user:         rawptr,     // the measure's and the sample's
}

// Where the picture is shown. Window pixels: the canvas box's, the offset from its top left, the zoom.
Edit_View :: struct {
	canvas: Edit_Box,
	zoom:   f32,        // window pixels per picture pixel
	offset: Edit_Vec,   // the picture's top left, from the canvas' top left
	fit:    bool,       // the picture is fitted to the canvas at each frame (until a zoom or a pan)
}

// Scale: one handle at the bottom right of a text, a step, a drawing, an emoji or a pointer, that makes all of it larger
// or smaller. Tail: a balloon's tail's tip.
Edit_Handle :: enum u8 { None, Top_Left, Top, Top_Right, Right, Bottom_Right, Bottom, Bottom_Left, Left, Start, End, Scale, Tail }
Edit_Handles :: bit_set[Edit_Handle; u16]

EDIT_BOX_HANDLES :: Edit_Handles{.Top_Left, .Top, .Top_Right, .Right, .Bottom_Right, .Bottom, .Bottom_Left, .Left}
EDIT_LINE_HANDLES :: Edit_Handles{.Start, .End}

// The interaction's states.
Edit_Idle     :: struct {}
Edit_Drawing  :: struct { index: int, start: Edit_Vec }                         // a new shape follows the pointer
Edit_Moving   :: struct { last: Edit_Vec }                                      // the shapes picked; picture pixels
// the press and the shape as it was (the whole shape as it was, for Scale: the document kept when the gesture began).
// index -1: the crop's box
Edit_Resizing :: struct { index: int, handle: Edit_Handle, start, a, b, c: Edit_Vec }
Edit_Panning  :: struct { last: Edit_Vec }                                      // window pixels
Edit_Cropping :: struct { start: Edit_Vec }
Edit_Cutting  :: struct { start, at: Edit_Vec }   // a band to cut out of the picture, picture pixels
Edit_Selecting :: struct { start, at: Edit_Vec, add: bool }   // a box that picks the shapes it touches; add: Shift
Edit_Typing   :: struct { index: int, before: string, fresh: bool }   // before: the text as it was (owned); fresh: a new text

Edit_Mode :: union #no_nil { Edit_Idle, Edit_Drawing, Edit_Moving, Edit_Resizing, Edit_Panning, Edit_Cropping, Edit_Cutting, Edit_Selecting, Edit_Typing }

Edit_Button :: enum u8 { Left, Middle, Right }

// The events, in window pixels. `pan`: Space is held (a left drag pans then).
Edit_Press    :: struct { at: Edit_Vec, button: Edit_Button, shift, pan, double: bool }
Edit_Move     :: struct { at: Edit_Vec, shift: bool }
Edit_Release  :: struct { at: Edit_Vec, button: Edit_Button, shift: bool }
Edit_Wheel    :: struct { at: Edit_Vec, delta: Edit_Vec, zoom, sideways: bool }   // delta: notches, +y away from the top
Edit_Typed    :: struct { text: string }   // the text field's text now (not kept)
Edit_Type_End :: struct { keep: bool }     // Enter or a press elsewhere keep the text; Escape gives back the one before

Edit_Event :: union { Edit_Press, Edit_Move, Edit_Release, Edit_Wheel, Edit_Typed, Edit_Type_End }

// A style's field that a slider or the colour picker runs through: the values of one run are one undo step.
Edit_Run_Field :: enum u8 { None, Color, Fill_Color, Width, Shadow, Radius }

Edit_Model :: struct {
	doc:    Edit_Doc,
	view:   Edit_View,
	mode:   Edit_Mode,
	tool:   Edit_Tool,
	styles: [Edit_Tool]Edit_Style,   // each tool's own, for its next shape (Select's: a picture's, a pointer's, an emoji's)
	typing: u32,   // counts the starts of Typing: the window puts the shape's text in its field at a new one
	// the last undo step was a run of `run_field` on this shape (its index + 1; 0: none), and the stack was this long
	// after it: the values a slider or the picker runs through are one step, not one a frame
	run_field: Edit_Run_Field,
	run_shape, run_undo: int,
}

edit_model_init :: proc(m: ^Edit_Model, size: [2]int, scale: f32, measure: Edit_Measure, user: rawptr, sample: Edit_Sample = nil) {
	m.doc = {size = {f32(size.x), f32(size.y)}, scale = scale > 0 ? scale : 1, selected = -1, step_start = 1, measure = measure, sample = sample, user = user}
	m.view = {zoom = 1, fit = true}
	m.mode = Edit_Idle{}
	m.tool = .Arrow
	for t in Edit_Tool { m.styles[t] = EDIT_STYLE_DEFAULT }
	m.styles[.Highlighter].color = EDIT_HIGHLIGHT_COLOR
	m.styles[.Highlighter].shadow = 0
	m.styles[.Pixelate].shadow = 0
	m.styles[.Blur].shadow = 0
	m.styles[.Eraser].shadow = 0
	m.styles[.Pen].heads = .None   // (a drawing; with a head it is a freehand arrow)
	m.styles[.Balloon] = EDIT_BALLOON_STYLE
	m.styles[.Select].text_size = EDIT_STICKER_SIZE
}

edit_model_destroy :: proc(m: ^Edit_Model) {
	if t, typing := m.mode.(Edit_Typing); typing { delete(t.before) }
	m.mode = Edit_Idle{}
	shapes_free(m.doc.shapes[:])
	delete(m.doc.shapes)
	delete(m.doc.ops)
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

edit_box_touches :: proc(r, s: Edit_Box) -> bool {
	return r.min.x <= s.max.x && s.min.x <= r.max.x && r.min.y <= s.max.y && s.min.y <= r.max.y
}

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

// Where each handle of a box is.
@(private = "file")
box_handles :: proc(r: Edit_Box) -> (at: [Edit_Handle]Edit_Vec) {
	c := (r.min + r.max) * 0.5
	at[.Top_Left], at[.Top], at[.Top_Right] = r.min, {c.x, r.min.y}, {r.max.x, r.min.y}
	at[.Right], at[.Bottom_Right], at[.Bottom] = {r.max.x, c.y}, r.max, {c.x, r.max.y}
	at[.Bottom_Left], at[.Left] = {r.min.x, r.max.y}, {r.min.x, c.y}
	return
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

// The zoom set to `zoom` (1: a picture's pixel a pixel of the screen, Ctrl+1), around the canvas' centre.
edit_view_zoom_to :: proc(m: ^Edit_Model, zoom: f32) {
	if m.view.zoom <= 0 { return }
	edit_view_zoom_centre(m, zoom / m.view.zoom)
}

// The picture's point at the canvas' centre, within the picture (where a paste lands without the pointer on the canvas).
edit_view_centre :: proc(m: ^Edit_Model) -> Edit_Vec {
	return picture_clamp(&m.doc, edit_to_picture(m.view, (m.view.canvas.min + m.view.canvas.max) * 0.5))
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
		if p.kind != q.kind || p.a != q.a || p.b != q.b || p.c != q.c || p.number != q.number || p.image != q.image || p.sample != q.sample || p.style != q.style || p.text != q.text { return false }
		if !slice.equal(p.points[:], q.points[:]) { return false }
	}
	return true
}

// The fill colour of a style, 0xRRGGBB; ok false: none.
edit_fill :: proc(style: Edit_Style) -> (rgb: u32, ok: bool) {
	return style.fill_color & 0xFFFFFF, style.fill_color >> 24 != 0
}

// The box a shape covers, without its stroke's width (a text's with its outline or its box, a balloon's with its tail).
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
	case .Text:
		return edit_box_pad(edit_box_of(s.a, s.b), edit_text_pad(doc, s))
	case .Balloon:
		r := edit_box_of(s.a, s.b)
		return {{min(r.min.x, s.c.x), min(r.min.y, s.c.y)}, {max(r.max.x, s.c.x), max(r.max.y, s.c.y)}}
	}
	return edit_box_of(s.a, s.b)
}

// A stroke's width in the picture's pixels.
edit_stroke_px :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return s.style.width * doc.scale }

edit_text_px :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return s.style.text_size * doc.scale }

edit_step_radius :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return edit_text_px(doc, s) * EDIT_STEP_RADIUS }

// How far a text's outline or box reaches past its letters, picture pixels.
edit_text_pad :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 {
	switch s.style.text_look {
	case .Plain:      return 0
	case .Outline:    return edit_text_px(doc, s) * EDIT_TEXT_OUTLINE * 0.5
	case .Background: return edit_text_px(doc, s) * EDIT_TEXT_BOX_PAD
	}
	return 0
}

// The room between a balloon's edge and its text, picture pixels.
edit_balloon_pad :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> f32 { return edit_text_px(doc, s) * EDIT_BALLOON_PAD }

// Where the first line of a shape's text starts (its top left), picture pixels: a text's and an emoji's top left, inside
// a balloon's edge.
edit_text_origin :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> Edit_Vec {
	if s.kind == .Balloon { return edit_box_of(s.a, s.b).min + edit_balloon_pad(doc, s) }
	return s.a
}

// A Pixelate's cell, a Blur's radius: in whole picture pixels, as the window makes their mosaics and blurred copies.
edit_pixel_cell :: proc(doc: ^Edit_Doc, style: Edit_Style) -> int { return max(int(math.round(style.pixel_size * doc.scale)), 1) }
edit_blur_px :: proc(doc: ^Edit_Doc, style: Edit_Style) -> int { return max(int(math.round(style.blur_radius * doc.scale)), 1) }

// The number the next step takes: one past the highest (a step deleted last is given again), and the start at least.
edit_step_next :: proc(doc: ^Edit_Doc) -> int {
	n := 0
	for s in doc.shapes { if s.kind == .Step { n = max(n, s.number) } }
	return max(n + 1, doc.step_start)
}

// How a step writes `n` in `format`, in `buf` (32 bytes are enough). A number letters or Roman numerals cannot write (0
// or less; past 3999 in Roman) is written in digits.
edit_step_label :: proc(buf: []u8, n: int, format: Edit_Step_Format) -> string {
	if n <= 0 || format == .Number || (format == .Roman && n > 3999) { return strconv.write_int(buf, i64(n), 10) }
	i := len(buf)
	switch format {
	case .Number:
	case .Lower, .Upper:
		// (as a spreadsheet's columns: z, then aa)
		first := format == .Lower ? u8('a') : u8('A')
		for v := n; v > 0 && i > 0; v = (v - 1) / 26 {
			i -= 1
			buf[i] = first + u8((v - 1) % 26)
		}
	case .Roman:
		@(static, rodata) values := [13]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
		@(static, rodata) marks := [13]string{"m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"}
		j, v := 0, n
		for k in 0 ..< len(values) {
			for v >= values[k] && j + len(marks[k]) <= len(buf) {
				copy(buf[j:], marks[k])
				j += len(marks[k])
				v -= values[k]
			}
		}
		return string(buf[:j])
	}
	return string(buf[i:])
}

// The size of a shape's text, line by line (an empty last line too: a line just begun with Shift+Enter has its room).
@(private = "file")
text_size_of :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) -> Edit_Vec {
	px := edit_text_px(doc, s)
	size := Edit_Vec{1, 0}
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		v := Edit_Vec{1, px}
		if doc.measure != nil { v = doc.measure(doc.user, line, px, s.style.bold) }
		size = {max(size.x, v.x), size.y + v.y}
		if nl < 0 { break }
		rest = rest[nl + 1:]
	}
	return {max(size.x, 1), max(size.y, 1)}
}

// A text's (an emoji's) box from its measure: its top left stays. A balloon grows to hold its text (it never shrinks
// by itself: its size is the person's).
@(private = "file")
text_measure :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) {
	#partial switch s.kind {
	case .Text, .Sticker:
		s.b = s.a + text_size_of(doc, s)
	case .Balloon:
		need := text_size_of(doc, s) + 2 * edit_balloon_pad(doc, s)
		r := edit_box_of(s.a, s.b)
		r.max = {max(r.max.x, r.min.x + need.x), max(r.max.y, r.min.y + need.y)}
		s.a, s.b = r.min, r.max
	}
}

// Whether `p` (picture pixels) touches the shape, `tolerance` picture pixels around its stroke.
edit_shape_hit :: proc(doc: ^Edit_Doc, s: ^Edit_Shape, p: Edit_Vec, tolerance: f32) -> bool {
	half := edit_stroke_px(doc, s) * 0.5 + tolerance
	_, filled := edit_fill(s.style)
	switch s.kind {
	case .Rectangle:
		r := edit_box_of(s.a, s.b)
		if filled { return edit_box_contains(edit_box_pad(r, half), p) }
		return edit_box_contains(edit_box_pad(r, half), p) && !edit_box_contains(edit_box_pad(r, -half), p)
	case .Ellipse:
		r := edit_box_of(s.a, s.b)
		c := (r.min + r.max) * 0.5
		radii := edit_box_size(r) * 0.5
		if radii.x < 1 || radii.y < 1 { return segment_distance(p, r.min, r.max) <= half }
		d := length((p - c) / radii)
		if filled { return d <= 1 + half / min(radii.x, radii.y) }
		return abs(d - 1) * min(radii.x, radii.y) <= half
	case .Arrow, .Line:
		return segment_distance(p, s.a, s.b) <= half
	case .Pen:
		if len(s.points) == 1 { return length(p - s.points[0]) <= half }
		for i in 1 ..< len(s.points) { if segment_distance(p, s.points[i - 1], s.points[i]) <= half { return true } }
		return false
	case .Balloon:
		// (its box, and its tail: from where it leaves the box to its tip)
		r := edit_box_of(s.a, s.b)
		if edit_box_contains(edit_box_pad(r, half), p) { return true }
		base := Edit_Vec{clamp(s.c.x, r.min.x, r.max.x), clamp(s.c.y, r.min.y, r.max.y)}
		return segment_distance(p, base, s.c) <= half + edit_text_px(doc, s) * 0.25
	case .Text, .Highlighter, .Pixelate, .Blur, .Eraser, .Magnify, .Image, .Cursor, .Sticker:
		return edit_box_contains(edit_box_pad(edit_shape_box(doc, s), tolerance), p)
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
	switch s.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate, .Blur, .Eraser, .Magnify, .Image:
		at = box_handles(edit_box_of(s.a, s.b))
		has = EDIT_BOX_HANDLES
	case .Balloon:
		at = box_handles(edit_box_of(s.a, s.b))
		at[.Tail] = s.c
		has = EDIT_BOX_HANDLES + {.Tail}
	case .Arrow, .Line:
		at[.Start], at[.End] = s.a, s.b
		has = EDIT_LINE_HANDLES
	case .Text, .Step, .Pen, .Sticker, .Cursor:
		at[.Scale] = edit_shape_box(doc, s).max
		has = {.Scale}
	}
	return
}

// The handle of the selected shape under `p` (picture pixels), within `tolerance`: when one shape is picked (the
// handles of several would be in each other's way).
edit_handle_hit :: proc(doc: ^Edit_Doc, p: Edit_Vec, tolerance: f32) -> Edit_Handle {
	if doc.selected < 0 || doc.selected >= len(doc.shapes) || doc.picked_count != 1 { return .None }
	at, has := edit_handles(doc, &doc.shapes[doc.selected])
	for h in Edit_Handle {
		if h in has && abs(p.x - at[h].x) <= tolerance && abs(p.y - at[h].y) <= tolerance { return h }
	}
	return .None
}

// The crop's handles (with the Crop tool, the crop drawn: it is adjusted by them).
edit_crop_handles :: proc(doc: ^Edit_Doc) -> (at: [Edit_Handle]Edit_Vec, has: Edit_Handles) {
	if !doc.has_crop { return }
	return box_handles(doc.crop), EDIT_BOX_HANDLES
}

@(private = "file")
crop_handle_hit :: proc(doc: ^Edit_Doc, p: Edit_Vec, tolerance: f32) -> Edit_Handle {
	at, has := edit_crop_handles(doc)
	for h in Edit_Handle {
		if h in has && abs(p.x - at[h].x) <= tolerance && abs(p.y - at[h].y) <= tolerance { return h }
	}
	return .None
}

@(private = "file")
shape_translate :: proc(s: ^Edit_Shape, d: Edit_Vec) {
	s.a += d
	s.b += d
	s.c += d
	for &p in s.points { p += d }
}

// The shape as it was (`a`, `b`, `c`) with `handle` moved by `d`. Shift keeps a line or an arrow straight or diagonal.
@(private = "file")
shape_resize :: proc(s: ^Edit_Shape, handle: Edit_Handle, a, b, c, d: Edit_Vec, shift: bool) {
	if handle == .Tail {
		s.c = c + d
		return
	}
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

// The scale handle moved by `d` from where it was: the shape as it was when the gesture began (`was`), scaled from its
// anchor (a text's or an emoji's top left, a step's centre, a drawing's or a pointer's top left) by how far the handle
// went along its diagonal.
@(private = "file")
shape_scale :: proc(doc: ^Edit_Doc, s: ^Edit_Shape, was: ^Edit_Shape, d: Edit_Vec) {
	box := edit_shape_box(doc, was)
	anchor := was.kind == .Pen ? box.min : was.a
	diag := box.max - anchor
	l2 := diag.x * diag.x + diag.y * diag.y
	if l2 <= 0 { return }
	q := box.max + d - anchor
	f := (q.x * diag.x + q.y * diag.y) / l2
	#partial switch s.kind {
	case .Text, .Step, .Sticker:
		s.style.text_size = clamp(was.style.text_size * f, EDIT_TEXT_SIZE_MIN, EDIT_TEXT_SIZE_MAX)
		if s.kind != .Step { text_measure(doc, s) }
	case .Pen:
		f = max(f, EDIT_SCALE_MIN)
		for p, i in was.points { if i < len(s.points) { s.points[i] = anchor + (p - anchor) * f } }
		s.a, s.b = anchor + (was.a - anchor) * f, anchor + (was.b - anchor) * f
	case .Cursor:
		f = max(f, EDIT_SCALE_MIN)
		s.b = was.a + (was.b - was.a) * f
	}
}

// Where a new balloon's tail goes: below its box, a third of the way in from its left.
@(private = "file")
balloon_tail :: proc(doc: ^Edit_Doc, a, b: Edit_Vec) -> Edit_Vec {
	r := edit_box_of(a, b)
	size := edit_box_size(r)
	return {r.min.x + size.x * 0.3, r.max.y + max(size.y * 0.5, EDIT_BALLOON_TAIL * doc.scale)}
}

// The colour around an eraser's box, from the picture as it is (the window reads it).
@(private = "file")
eraser_sample :: proc(doc: ^Edit_Doc, s: ^Edit_Shape) {
	if s.kind != .Eraser || doc.sample == nil { return }
	s.sample = doc.sample(doc.user, edit_box_of(s.a, s.b))
}

////////////////////////////////
// The selection

// Only shape `i` picked (and shown in the bar); -1: none.
@(private = "file")
select_only :: proc(doc: ^Edit_Doc, i: int) {
	for &s in doc.shapes { s.picked = false }
	doc.selected = -1
	if i >= 0 && i < len(doc.shapes) {
		doc.shapes[i].picked = true
		doc.selected = i
	}
	picks_update(doc)
}

// The count and the kinds of the shapes picked, made again after the picks or the shapes changed; the one the bar shows
// stays one of them.
@(private = "file")
picks_update :: proc(doc: ^Edit_Doc) {
	doc.picked_count, doc.picked_kinds = 0, {}
	last := -1
	for s, i in doc.shapes {
		if !s.picked { continue }
		doc.picked_count += 1
		doc.picked_kinds += {s.kind}
		last = i
	}
	if doc.selected < 0 || doc.selected >= len(doc.shapes) || !doc.shapes[doc.selected].picked { doc.selected = last }
}

// Shape `i` alone selected (-1: none): what a click on it does.
edit_select :: proc(m: ^Edit_Model, i: int) {
	if !edit_idle(m) { return }
	select_only(&m.doc, i)
}

edit_selection_count :: proc(m: ^Edit_Model) -> int { return m.doc.picked_count }

////////////////////////////////
// The picture's operations

// The picture's size after `op`, from `size`.
edit_op_size :: proc(op: Edit_Op, size: Edit_Vec) -> Edit_Vec {
	switch op.kind {
	case .Rotate: return op.turns % 2 != 0 ? Edit_Vec{size.y, size.x} : size
	case .Flip:   return size
	case .Resize: return {f32(op.size.x), f32(op.size.y)}
	case .Canvas: return size + {f32(op.margins[0] + op.margins[2]), f32(op.margins[1] + op.margins[3])}
	case .Cut:    return op.across ? size - {f32(op.length), 0} : size - {0, f32(op.length)}
	}
	return size
}

// Where `op` takes the picture's point `p`, the picture of `size` before it. A point in a band cut out goes to its edge.
edit_op_point :: proc(op: Edit_Op, size, p: Edit_Vec) -> Edit_Vec {
	switch op.kind {
	case .Rotate:
		switch ((op.turns % 4) + 4) % 4 {
		case 1: return {size.y - p.y, p.x}
		case 2: return size - p
		case 3: return {p.y, size.x - p.x}
		}
		return p
	case .Flip:
		return op.across ? Edit_Vec{size.x - p.x, p.y} : Edit_Vec{p.x, size.y - p.y}
	case .Resize:
		return p * Edit_Vec{f32(op.size.x) / size.x, f32(op.size.y) / size.y}
	case .Canvas:
		return p + {f32(op.margins[0]), f32(op.margins[1])}
	case .Cut:
		a, b := f32(op.at), f32(op.at + op.length)
		v := op.across ? p.x : p.y
		if v >= b { v -= f32(op.length) } else if v > a { v = a }
		return op.across ? Edit_Vec{v, p.y} : Edit_Vec{p.x, v}
	}
	return p
}

// `op` made to fit the picture of `size`; ok false: it would change nothing, or leave no picture.
@(private = "file")
op_fit :: proc(op: Edit_Op, size: Edit_Vec) -> (out: Edit_Op, ok: bool) {
	out = op
	w, h := int(size.x), int(size.y)
	switch op.kind {
	case .Rotate:
		out.turns = ((op.turns % 4) + 4) % 4
		return out, out.turns != 0
	case .Flip:
		return out, true
	case .Resize:
		return out, op.size.x >= 1 && op.size.y >= 1 && op.size.x <= EDIT_PICTURE_MAX && op.size.y <= EDIT_PICTURE_MAX && op.size != [2]int{w, h}
	case .Canvas:
		for v in op.margins { if v < 0 { return out, false } }
		m := op.margins
		return out, m != [4]int{} && w + m[0] + m[2] <= EDIT_PICTURE_MAX && h + m[1] + m[3] <= EDIT_PICTURE_MAX
	case .Cut:
		n := op.across ? w : h
		a, b := clamp(op.at, 0, n), clamp(op.at + max(op.length, 0), 0, n)
		out.at, out.length = a, b - a
		return out, out.length >= 1 && out.length < n
	}
	return out, false
}

// The shape where `op` takes it, the picture of `size` before it. Letters, emoji, pictures and pointers stay upright
// when the picture turns: their centre goes where the picture takes it.
@(private = "file")
shape_through :: proc(s: ^Edit_Shape, op: Edit_Op, size: Edit_Vec) {
	f :: proc(op: Edit_Op, size, p: Edit_Vec) -> Edit_Vec { return edit_op_point(op, size, p) }
	#partial switch s.kind {
	case .Step:
		s.a = f(op, size, s.a)
		s.b = s.a
		return
	case .Text, .Sticker, .Image, .Cursor:
		if op.kind == .Rotate || op.kind == .Flip || (op.kind == .Cut && s.kind != .Image && s.kind != .Cursor) {
			half := (s.b - s.a) * 0.5
			c := f(op, size, s.a + half)
			s.a, s.b = c - half, c + half
			return
		}
	}
	s.a, s.b, s.c = f(op, size, s.a), f(op, size, s.b), f(op, size, s.c)
	for &p in s.points { p = f(op, size, p) }
	#partial switch s.kind {
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate, .Blur, .Eraser, .Magnify, .Balloon, .Image, .Cursor:
		r := edit_box_of(s.a, s.b)
		s.a, s.b = r.min, r.max
	}
}

// `op` done to the picture: its size, its scale (a resize makes the strokes and the letters follow), the shapes and the
// crop go where it takes them; one undo step. False: it changes nothing (a turn of 0, a resize to the same size, a
// band of nothing or of all of it).
edit_picture_change :: proc(m: ^Edit_Model, op: Edit_Op) -> bool {
	doc := &m.doc
	if !edit_idle(m) { return false }
	o, ok := op_fit(op, doc.size)
	if !ok { return false }
	change_begin(doc)
	before := doc.size
	doc.size = edit_op_size(o, before)
	if o.kind == .Resize { doc.scale *= math.sqrt(doc.size.x / before.x * doc.size.y / before.y) }
	for &s in doc.shapes {
		shape_through(&s, o, before)
		if s.kind == .Text || s.kind == .Sticker { text_measure(doc, &s) }
	}
	if doc.has_crop {
		r := edit_box_of(edit_op_point(o, before, doc.crop.min), edit_op_point(o, before, doc.crop.max))
		r = {picture_clamp(doc, r.min), picture_clamp(doc, r.max)}
		size := edit_box_size(r)
		doc.crop, doc.has_crop = r, size.x >= 1 && size.y >= 1
		if !doc.has_crop { doc.crop = {} }
	}
	append(&doc.ops, o)
	change_end(doc)
	return true
}

// The band a cut out's drag gives, from `start` to `at` (picture pixels): of columns when it goes more across than down.
edit_cut_op :: proc(doc: ^Edit_Doc, start, at: Edit_Vec) -> Edit_Op {
	d := at - start
	across := abs(d.x) >= abs(d.y)
	lo := int(math.round(across ? min(start.x, at.x) : min(start.y, at.y)))
	hi := int(math.round(across ? max(start.x, at.x) : max(start.y, at.y)))
	return {kind = .Cut, across = across, at = lo, length = hi - lo}
}

// The band being cut out (picture pixels), the whole height or width of the picture; ok false: no cut going on.
edit_cut_shown :: proc(m: ^Edit_Model) -> (band: Edit_Box, ok: bool) {
	s := m.mode.(Edit_Cutting) or_return
	op := edit_cut_op(&m.doc, s.start, s.at)
	if op.across { return {{f32(op.at), 0}, {f32(op.at + op.length), m.doc.size.y}}, true }
	return {{0, f32(op.at)}, {m.doc.size.x, f32(op.at + op.length)}}, true
}

// The box of a box selection going on (picture pixels); ok false: none.
edit_selecting_shown :: proc(m: ^Edit_Model) -> (box: Edit_Box, ok: bool) {
	s := m.mode.(Edit_Selecting) or_return
	return edit_box_of(s.start, s.at), true
}

////////////////////////////////
// Undo and redo

@(private = "file")
snapshot_take :: proc(doc: ^Edit_Doc) -> Edit_Snapshot {
	out := Edit_Snapshot{shapes = make([]Edit_Shape, len(doc.shapes)), crop = doc.crop, has_crop = doc.has_crop, ops = slice.clone(doc.ops[:]), size = doc.size, scale = doc.scale}
	for s, i in doc.shapes { out.shapes[i] = shape_clone(s) }
	return out
}

@(private = "file")
snapshot_free :: proc(s: ^Edit_Snapshot) {
	shapes_free(s.shapes)
	delete(s.shapes)
	delete(s.ops)
	s^ = {}
}

// The document becomes `s` (taken: its shapes are the document's now). Nothing is selected.
@(private = "file")
snapshot_restore :: proc(doc: ^Edit_Doc, s: Edit_Snapshot) {
	shapes_free(doc.shapes[:])
	clear(&doc.shapes)
	append(&doc.shapes, ..s.shapes)
	delete(s.shapes)
	clear(&doc.ops)
	append(&doc.ops, ..s.ops)
	delete(s.ops)
	doc.crop, doc.has_crop = s.crop, s.has_crop
	doc.size, doc.scale = s.size, s.scale
	select_only(doc, -1)
	doc.revision += 1
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
	picks_update(doc)
	if !doc.has_pending { return }
	doc.has_pending = false
	p := doc.pending
	doc.pending = {}
	if shapes_equal(p.shapes, doc.shapes[:]) && p.crop == doc.crop && p.has_crop == doc.has_crop && slice.equal(p.ops, doc.ops[:]) {
		snapshot_free(&p)
		return
	}
	undo.push(&doc.history, p, 0, snapshot_free)
	doc.revision += 1
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

// The shape the bar shows: the one picked last.
edit_selected_shape :: proc(m: ^Edit_Model) -> ^Edit_Shape {
	return edit_has_selection(m) ? &m.doc.shapes[m.doc.selected] : nil
}

// Adds a shape (taken: its points and text are the document's now) on top, alone selected; one undo step.
edit_add :: proc(m: ^Edit_Model, s: Edit_Shape) -> int {
	change_begin(&m.doc)
	append(&m.doc.shapes, s)
	i := len(m.doc.shapes) - 1
	text_measure(&m.doc, &m.doc.shapes[i])
	eraser_sample(&m.doc, &m.doc.shapes[i])
	select_only(&m.doc, i)
	change_end(&m.doc)
	return i
}

// The shapes picked taken away; one undo step.
edit_delete :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	change_begin(&m.doc)
	#reverse for &s, i in m.doc.shapes[:] {
		if !s.picked { continue }
		shape_free(&s)
		ordered_remove(&m.doc.shapes, i)
	}
	m.doc.selected = -1
	change_end(&m.doc)
	return true
}

// Every shape taken away (the crop stays); one undo step.
edit_delete_all :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || len(m.doc.shapes) == 0 { return false }
	change_begin(&m.doc)
	shapes_free(m.doc.shapes[:])
	clear(&m.doc.shapes)
	m.doc.selected = -1
	change_end(&m.doc)
	return true
}

// Where the shapes picked go among the others: on top of all, under all, one up, one down.
Edit_Order :: enum u8 { Front, Back, Forward, Backward }

// The shapes' new order (each place: the index of the shape it takes); changed false: they are there already (or
// nothing is picked). Several picked keep their order among themselves; one step moves each past one other.
@(private = "file")
order_plan :: proc(m: ^Edit_Model, o: Edit_Order) -> (order: []int, changed: bool) {
	if !edit_idle(m) || !edit_has_selection(m) { return }
	shapes := m.doc.shapes[:]
	n := len(shapes)
	order = make([]int, n, context.temp_allocator)
	switch o {
	case .Front, .Back:
		j := 0
		for pass in 0 ..< 2 {
			// (Front: the others, then the picked; Back: the other way)
			want := (pass == 0) == (o == .Back)
			for s, i in shapes { if s.picked == want { order[j] = i; j += 1 } }
		}
	case .Forward:
		for i in 0 ..< n { order[i] = i }
		for i := n - 2; i >= 0; i -= 1 {
			if shapes[order[i]].picked && !shapes[order[i + 1]].picked { order[i], order[i + 1] = order[i + 1], order[i] }
		}
	case .Backward:
		for i in 0 ..< n { order[i] = i }
		for i in 1 ..< n {
			if shapes[order[i]].picked && !shapes[order[i - 1]].picked { order[i], order[i - 1] = order[i - 1], order[i] }
		}
	}
	for v, i in order { if v != i { changed = true } }
	return
}

edit_can_order :: proc(m: ^Edit_Model, o: Edit_Order) -> bool {
	_, ok := order_plan(m, o)
	return ok
}

// The shapes picked moved in the order (Home, End, Page Up, Page Down); one undo step. They stay selected.
edit_order :: proc(m: ^Edit_Model, o: Edit_Order) -> bool {
	order, ok := order_plan(m, o)
	if !ok { return false }
	change_begin(&m.doc)
	was := slice.clone(m.doc.shapes[:], context.temp_allocator)
	shown := m.doc.selected
	for v, i in order {
		m.doc.shapes[i] = was[v]
		if v == shown { m.doc.selected = i }
	}
	change_end(&m.doc)
	return true
}

// A copy of each shape picked, a little below and right of it, on top; the copies are the selection then. A step's
// copy takes the next number. One undo step.
edit_duplicate :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	doc := &m.doc
	change_begin(doc)
	n := len(doc.shapes)
	shown := -1
	for i in 0 ..< n {
		if !doc.shapes[i].picked { continue }
		c := shape_clone(doc.shapes[i])
		shape_translate(&c, Edit_Vec{1, 1} * (EDIT_DUPLICATE_PX * doc.scale))
		if c.kind == .Step { c.number = edit_step_next(doc) }
		doc.shapes[i].picked = false
		if i == doc.selected { shown = len(doc.shapes) }
		append(&doc.shapes, c)
	}
	doc.selected = shown
	change_end(doc)
	return true
}

// Moves the shapes picked by `d` picture pixels (the arrow keys).
edit_nudge :: proc(m: ^Edit_Model, d: Edit_Vec) -> bool {
	if !edit_idle(m) || !edit_has_selection(m) { return false }
	change_begin(&m.doc)
	for &s in m.doc.shapes {
		if !s.picked { continue }
		shape_translate(&s, d)
		eraser_sample(&m.doc, &s)
	}
	change_end(&m.doc)
	return true
}

edit_deselect :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || m.doc.selected < 0 { return false }
	select_only(&m.doc, -1)
	return true
}

// Every shape selected (Ctrl+A).
edit_select_all :: proc(m: ^Edit_Model) -> bool {
	if !edit_idle(m) || len(m.doc.shapes) == 0 { return false }
	for &s in m.doc.shapes { s.picked = true }
	picks_update(&m.doc)
	return true
}

// A text from the clipboard (not kept), as a text of the Text tool's style, its top left at `at` (picture pixels); one
// undo step. Its line ends become "\n"; an empty text is no text.
edit_paste_text :: proc(m: ^Edit_Model, text: string, at: Edit_Vec) -> bool {
	if !edit_idle(m) { return false }
	t, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	t, _ = strings.replace_all(t, "\r", "\n", context.temp_allocator)
	t = strings.trim_right(t, "\n")
	if strings.trim_space(t) == "" { return false }
	edit_add(m, {kind = .Text, a = picture_clamp(&m.doc, at), text = strings.clone(t), style = m.styles[.Text]})
	return true
}

// A picture (pasted, from a file, from the screen) of `size` pixels, held by the window as `image` (never 0): centred
// on `at` (picture pixels), at its own pixels, or smaller to fit the picture; one undo step. Its style is the Select
// tool's (its shadow).
edit_paste_image :: proc(m: ^Edit_Model, image: u32, size: [2]int, at: Edit_Vec) -> bool {
	if !edit_idle(m) || image == 0 || size.x <= 0 || size.y <= 0 { return false }
	s := Edit_Vec{f32(size.x), f32(size.y)}
	k := min(1, m.doc.size.x * EDIT_PASTE_FIT / s.x, m.doc.size.y * EDIT_PASTE_FIT / s.y)
	s *= k
	a := picture_clamp(&m.doc, at) - s * 0.5
	edit_add(m, {kind = .Image, a = a, b = a + s, image = image, style = m.styles[.Select]})
	return true
}

// A mouse pointer, its tip at `at` (picture pixels); one undo step.
edit_add_cursor :: proc(m: ^Edit_Model, at: Edit_Vec) -> bool {
	if !edit_idle(m) { return false }
	a := picture_clamp(&m.doc, at)
	edit_add(m, {kind = .Cursor, a = a, b = a + EDIT_CURSOR_SIZE * m.doc.scale, style = m.styles[.Select]})
	return true
}

// An emoji (not kept) centred on `at` (picture pixels), at the Select tool's text size; one undo step.
edit_add_sticker :: proc(m: ^Edit_Model, emoji: string, at: Edit_Vec) -> bool {
	if !edit_idle(m) || emoji == "" { return false }
	s := Edit_Shape{kind = .Sticker, a = picture_clamp(&m.doc, at), text = strings.clone(emoji), style = m.styles[.Select]}
	text_measure(&m.doc, &s)
	shape_translate(&s, (s.a - s.b) * 0.5)
	edit_add(m, s)
	return true
}

// A tool chosen: a drawing tool lets go of the selection (its properties are the tool's then).
edit_tool_set :: proc(m: ^Edit_Model, t: Edit_Tool) {
	m.tool = t
	if t != .Select && edit_idle(m) { select_only(&m.doc, -1) }
}

// The kind of shape a tool draws (ok false: Select, Crop, Cut_Out).
edit_tool_kind :: proc(t: Edit_Tool) -> (k: Edit_Kind, ok: bool) {
	switch t {
	case .Select, .Crop, .Cut_Out: return
	case .Rectangle:   return .Rectangle, true
	case .Ellipse:     return .Ellipse, true
	case .Arrow:       return .Arrow, true
	case .Line:        return .Line, true
	case .Pen:         return .Pen, true
	case .Text:        return .Text, true
	case .Balloon:     return .Balloon, true
	case .Highlighter: return .Highlighter, true
	case .Pixelate:    return .Pixelate, true
	case .Blur:        return .Blur, true
	case .Eraser:      return .Eraser, true
	case .Magnify:     return .Magnify, true
	case .Step:        return .Step, true
	}
	return
}

// The tool whose style a kind's shape takes and gives back (a picture, a pointer, an emoji: Select's, no tool draws them).
edit_kind_tool :: proc(k: Edit_Kind) -> Edit_Tool {
	switch k {
	case .Rectangle:   return .Rectangle
	case .Ellipse:     return .Ellipse
	case .Arrow:       return .Arrow
	case .Line:        return .Line
	case .Pen:         return .Pen
	case .Text:        return .Text
	case .Balloon:     return .Balloon
	case .Highlighter: return .Highlighter
	case .Pixelate:    return .Pixelate
	case .Blur:        return .Blur
	case .Eraser:      return .Eraser
	case .Magnify:     return .Magnify
	case .Step:        return .Step
	case .Image, .Cursor, .Sticker: return .Select
	}
	return .Select
}

// The style the properties' bar shows, and which of its properties apply: the selection's (what all the shapes picked
// have; a step's number is one step's), else the tool's.
edit_style_shown :: proc(m: ^Edit_Model) -> (style: Edit_Style, props: Edit_Props) {
	if s := edit_selected_shape(m); s != nil {
		props = EDIT_PROPS[s.kind]
		if m.doc.picked_count > 1 {
			for k in m.doc.picked_kinds { props &= EDIT_PROPS[k] }
			props -= {.Step_Number}
		}
		return s.style, props
	}
	if k, ok := edit_tool_kind(m.tool); ok { return m.styles[m.tool], EDIT_PROPS[k] }
	return EDIT_STYLE_DEFAULT, {}
}

// `to` with the fields that differ between `was` and `now` set to `now`'s: a change of the bar, given to every shape
// picked without changing what they do not share.
@(private = "file")
style_merge :: proc(to, was, now: Edit_Style) -> Edit_Style {
	out := to
	if was.color != now.color             { out.color = now.color }
	if was.fill_color != now.fill_color   { out.fill_color = now.fill_color }
	if was.width != now.width             { out.width = now.width }
	if was.shadow != now.shadow           { out.shadow = now.shadow }
	if was.text_size != now.text_size     { out.text_size = now.text_size }
	if was.text_look != now.text_look     { out.text_look = now.text_look }
	if was.bold != now.bold               { out.bold = now.bold }
	if was.step_format != now.step_format { out.step_format = now.step_format }
	if was.blur_radius != now.blur_radius { out.blur_radius = now.blur_radius }
	if was.pixel_size != now.pixel_size   { out.pixel_size = now.pixel_size }
	if was.dash != now.dash               { out.dash = now.dash }
	if was.radius != now.radius           { out.radius = now.radius }
	if was.heads != now.heads             { out.heads = now.heads }
	if was.zoom != now.zoom               { out.zoom = now.zoom }
	if was.lens != now.lens               { out.lens = now.lens }
	return out
}

// A property set: on the shapes picked (one undo step) and on the tool that draws the one shown, else on the current
// tool. The values of one field that a slider or the colour picker runs through, one after the other on one selection,
// are one step.
edit_style_set :: proc(m: ^Edit_Model, style: Edit_Style) -> bool {
	if !edit_idle(m) { return false }
	if s := edit_selected_shape(m); s != nil {
		if s.style == style { return false }
		was := s.style
		field := run_field(was, style)
		run := field != .None && m.run_field == field && m.run_shape == m.doc.selected + 1 && m.run_undo == len(m.doc.history.undo) && !undo.can_redo(&m.doc.history)
		if !run { change_begin(&m.doc) }
		for &x in m.doc.shapes {
			if !x.picked { continue }
			x.style = style_merge(x.style, was, style)
			text_measure(&m.doc, &x)
		}
		if !run { change_end(&m.doc) }
		m.doc.revision += 1
		m.run_field, m.run_shape, m.run_undo = field, field != .None ? m.doc.selected + 1 : 0, len(m.doc.history.undo)
		m.styles[edit_kind_tool(m.doc.shapes[m.doc.selected].kind)] = style
		return true
	}
	if _, ok := edit_tool_kind(m.tool); !ok { return false }
	m.styles[m.tool] = style
	return true
}

// The one field that differs between two styles, when it is one a run goes through; None: another, or several.
@(private = "file")
run_field :: proc(a, b: Edit_Style) -> Edit_Run_Field {
	x, y := a, b
	field := Edit_Run_Field.None
	if x.color != y.color { field = .Color; x.color = y.color }
	if x.fill_color != y.fill_color { if field != .None { return .None }; field = .Fill_Color; x.fill_color = y.fill_color }
	if x.width != y.width { if field != .None { return .None }; field = .Width; x.width = y.width }
	if x.shadow != y.shadow { if field != .None { return .None }; field = .Shadow; x.shadow = y.shadow }
	if x.radius != y.radius { if field != .None { return .None }; field = .Radius; x.radius = y.radius }
	return x == y ? field : .None
}

// The number the Step's options show: the selected step's, else the one the next step takes.
edit_step_number_shown :: proc(m: ^Edit_Model) -> int {
	if s := edit_selected_shape(m); s != nil && s.kind == .Step { return s.number }
	return edit_step_next(&m.doc)
}

// The Step's number set: the selected step's (one undo step), else the least number the next step takes.
edit_step_number_set :: proc(m: ^Edit_Model, n: int) -> bool {
	if !edit_idle(m) || n < 1 { return false }
	if s := edit_selected_shape(m); s != nil && s.kind == .Step {
		if s.number == n { return false }
		change_begin(&m.doc)
		s.number = n
		change_end(&m.doc)
		return true
	}
	if m.doc.step_start == n { return false }
	m.doc.step_start = n
	return true
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

// The crop set to `box` (picture pixels, within the picture): an auto crop; one undo step. False: it keeps all of the
// picture, or it is the crop already.
edit_crop_set :: proc(m: ^Edit_Model, box: Edit_Box) -> bool {
	if !edit_idle(m) { return false }
	r := Edit_Box{picture_clamp(&m.doc, box.min), picture_clamp(&m.doc, box.max)}
	size := edit_box_size(r)
	if size.x < 1 || size.y < 1 || (r.min == {0, 0} && r.max == m.doc.size) { return false }
	if m.doc.has_crop && m.doc.crop == r { return false }
	change_begin(&m.doc)
	m.doc.crop, m.doc.has_crop = r, true
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
			if sh.kind == .Balloon { r = edit_box_of(sh.a, sh.b) }
			small := max(r.max.x - r.min.x, r.max.y - r.min.y) * m.view.zoom < EDIT_SMALL_PX
			#partial switch sh.kind {
			case .Rectangle, .Ellipse, .Arrow, .Line, .Highlighter, .Pixelate, .Blur, .Eraser, .Magnify, .Balloon:
				if small {
					shape_free(sh)
					ordered_remove(&doc.shapes, s.index)
					select_only(doc, -1)
					change_end(doc)
					m.mode = Edit_Idle{}
					return true
				}
			}
			eraser_sample(doc, sh)
			if sh.kind == .Balloon {
				// (its words next, in the same undo step: the step began with the drawing)
				m.mode = Edit_Typing{index = s.index, before = strings.clone(sh.text), fresh = true}
				m.typing += 1
				return true
			}
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Moving:
		#partial switch v in e {
		case Edit_Move:
			p := edit_to_picture(m.view, v.at)
			picked_translate(doc, p - s.last)
			s.last = p
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			p := edit_to_picture(m.view, v.at)
			picked_translate(doc, p - s.last)
			for &x in doc.shapes { if x.picked { eraser_sample(doc, &x) } }
			change_end(doc)
			m.mode = Edit_Idle{}
			return true
		}
	case Edit_Resizing:
		#partial switch v in e {
		case Edit_Move:
			resizing_follow(m, s, edit_to_picture(m.view, v.at), v.shift)
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			resizing_follow(m, s, edit_to_picture(m.view, v.at), v.shift)
			if s.index >= 0 {
				eraser_sample(doc, &doc.shapes[s.index])
			} else {
				r := edit_box_size(doc.crop)
				if r.x < 1 || r.y < 1 { doc.has_crop, doc.crop = false, Edit_Box{} }
			}
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
	case Edit_Cutting:
		#partial switch v in e {
		case Edit_Move:
			s.at = picture_clamp(doc, edit_to_picture(m.view, v.at))
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			s.at = picture_clamp(doc, edit_to_picture(m.view, v.at))
			op := edit_cut_op(doc, s.start, s.at)
			m.mode = Edit_Idle{}
			// (a click cuts nothing)
			if f32(op.length) * m.view.zoom >= EDIT_SMALL_PX { edit_picture_change(m, op) }
			return true
		}
	case Edit_Selecting:
		#partial switch v in e {
		case Edit_Move:
			s.at = edit_to_picture(m.view, v.at)
			return true
		case Edit_Release:
			if v.button != .Left { return false }
			s.at = edit_to_picture(m.view, v.at)
			box := edit_box_of(s.start, s.at)
			size := edit_box_size(box) * m.view.zoom
			if max(size.x, size.y) >= EDIT_SMALL_PX {
				// (what it touches, as a press takes a shape near its stroke)
				for &x, i in doc.shapes {
					if !edit_box_touches(box, edit_shape_box(doc, &x)) { continue }
					x.picked = true
					doc.selected = i
				}
			}
			picks_update(doc)
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
picked_translate :: proc(doc: ^Edit_Doc, d: Edit_Vec) {
	for &x in doc.shapes { if x.picked { shape_translate(&x, d) } }
}

@(private = "file")
idle_press :: proc(m: ^Edit_Model, v: Edit_Press) -> bool {
	doc := &m.doc
	if v.button == .Middle || (v.button == .Left && v.pan) {
		m.mode = Edit_Panning{last = v.at}
		m.view.fit = false
		return true
	}
	p := edit_to_picture(m.view, v.at)
	tolerance := EDIT_HIT_PX / m.view.zoom
	if v.button == .Right {
		// (a right press on a shape selects it, with any tool: the window opens its menu; on a shape of the selection,
		// the selection stays, for its menu; elsewhere it means nothing)
		hit := edit_hit(doc, p, tolerance)
		if hit < 0 { return false }
		if doc.shapes[hit].picked { doc.selected = hit } else { select_only(doc, hit) }
		return true
	}
	if m.tool == .Crop {
		// (the crop's handles adjust it; a press elsewhere draws another)
		if h := crop_handle_hit(doc, p, EDIT_HANDLE_PX / m.view.zoom); h != .None {
			change_begin(doc)
			m.mode = Edit_Resizing{index = -1, handle = h, start = p, a = doc.crop.min, b = doc.crop.max}
			return true
		}
		change_begin(doc)
		start := picture_clamp(doc, p)
		m.mode = Edit_Cropping{start = start}
		doc.crop, doc.has_crop = Edit_Box{start, start}, true
		return true
	}
	if m.tool == .Cut_Out {
		start := picture_clamp(doc, p)
		m.mode = Edit_Cutting{start = start, at = start}
		return true
	}
	// (the selected shape's handles first, with any tool: a shape just drawn is resized at once)
	if h := edit_handle_hit(doc, p, EDIT_HANDLE_PX / m.view.zoom); h != .None {
		sh := &doc.shapes[doc.selected]
		change_begin(doc)
		m.mode = Edit_Resizing{index = doc.selected, handle = h, start = p, a = sh.a, b = sh.b, c = sh.c}
		return true
	}
	hit := edit_hit(doc, p, tolerance)
	if hit >= 0 && !v.shift {
		k := doc.shapes[hit].kind
		if (k == .Text || k == .Balloon) && (v.double || m.tool == edit_kind_tool(k)) {
			typing_start(m, hit, fresh = false)
			return true
		}
	}
	if m.tool == .Select && v.shift {
		// (Shift: a shape added to the selection or taken from it; elsewhere a box that adds what it touches)
		if hit >= 0 {
			doc.shapes[hit].picked = !doc.shapes[hit].picked
			if doc.shapes[hit].picked { doc.selected = hit }
			picks_update(doc)
			return true
		}
		m.mode = Edit_Selecting{start = p, at = p, add = true}
		return true
	}
	// (Select takes any shape; a drawing tool takes one of the selection, and draws over the others)
	if hit >= 0 && (m.tool == .Select || doc.shapes[hit].picked) {
		if doc.shapes[hit].picked { doc.selected = hit } else { select_only(doc, hit) }
		change_begin(doc)
		m.mode = Edit_Moving{last = p}
		return true
	}
	kind, draws := edit_tool_kind(m.tool)
	if !draws {
		// (Select on nothing: a box that picks what it touches)
		select_only(doc, -1)
		m.mode = Edit_Selecting{start = p, at = p}
		return true
	}
	change_begin(doc)
	sh := Edit_Shape{kind = kind, a = p, b = p, c = p, style = m.styles[m.tool]}
	#partial switch kind {
	case .Pen:  append(&sh.points, p)
	case .Step: sh.number = edit_step_next(doc)
	}
	append(&doc.shapes, sh)
	i := len(doc.shapes) - 1
	select_only(doc, i)
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
	case .Rectangle, .Ellipse, .Highlighter, .Pixelate, .Blur, .Eraser, .Magnify:
		sh.b = shift ? edit_square(sh.a, p) : p
	case .Balloon:
		sh.b = shift ? edit_square(sh.a, p) : p
		sh.c = balloon_tail(&m.doc, sh.a, sh.b)
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

// A handle follows the pointer: a box's side or corner, a line's end, a balloon's tail, the scale of a text, a step or a
// drawing, or a side or a corner of the crop.
@(private = "file")
resizing_follow :: proc(m: ^Edit_Model, s: Edit_Resizing, p: Edit_Vec, shift: bool) {
	doc := &m.doc
	if s.index < 0 {
		box: Edit_Shape
		shape_resize(&box, s.handle, s.a, s.b, s.c, p - s.start, false)
		doc.crop = edit_box_of(picture_clamp(doc, box.a), picture_clamp(doc, box.b))
		doc.has_crop = true
		return
	}
	sh := &doc.shapes[s.index]
	if s.handle == .Scale {
		// (the shape as the gesture found it: change_begin kept the whole document)
		if !doc.has_pending || s.index >= len(doc.pending.shapes) { return }
		shape_scale(doc, sh, &doc.pending.shapes[s.index], p - s.start)
		return
	}
	shape_resize(sh, s.handle, s.a, s.b, s.c, p - s.start, shift)
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
	select_only(&m.doc, index)
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
	// (a text left empty, or only blanks, is no text; a balloon stays: its box says something by itself)
	if sh.kind == .Text && strings.trim_space(sh.text) == "" {
		shape_free(sh)
		ordered_remove(&doc.shapes, s.index)
		select_only(doc, -1)
	} else {
		select_only(doc, s.index)
	}
	delete(s.before)
	change_end(doc)
	m.mode = Edit_Idle{}
}
