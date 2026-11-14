package cliche

// The editor's picture, drawn: on the screen (editor.odin, at the view's zoom) and flattened for the after-capture chain
// (here, at the picture's own size). One procedure paints both, so the file looks as the canvas did.
//
// Flattening draws the composition into offscreen targets (gt:draw's offscreen_begin, at most EDIT_TILE pixels a side:
// a target larger than the device allows is refused) during a frame of the editor's window, and reads them back
// (render.readback_poll) a frame or two later. The renderer converts what it reads to straight RGBA; a picture of
// several tiles is put together here, once.
//
// Pixelate draws a mosaic: the picture's mean colour by cells of its pixel size, on one grid for the whole picture. Blur
// draws a blurred copy of the picture: a mosaic of cells a quarter of its radius, blurred, which the GPU stretches back
// (a blur hides the detail a smaller copy loses anyway; the copy is small and quick to make). A task of the chores
// makes each mosaic and each blurred copy once per picture and size (they go through every pixel; editor.odin).

import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "gt:draw"
import "gt:font"
import pic "gt:image"
import "gt:render"

EDIT_TILE          :: 4096   // the side of an offscreen target of the export, at most
EDIT_BLUR_DOWN     :: 4      // a blurred copy's cell, in parts of its radius
EDIT_SHADOW_FALL   :: 0.8    // how far the shadow falls down and right, per pixel of its softness (Edit_Style.shadow)
EDIT_SHADOW_COLOR  :: draw.Color{0, 0, 0, 0.6}
EDIT_STEP_RING     :: 0.12   // a step's ring around a disc of its fill colour, in its radius
EDIT_STEP_LABEL    :: 1.6    // the widest a step's label is, in its radius (a longer one is written smaller)
EDIT_TEXT_BOX_ROUND :: 0.2   // a text's box's corners, in its text size
EDIT_BALLOON_ROUND  :: 0.6   // a balloon's corners, in its text size
EDIT_BALLOON_BASE   :: 0.25  // the width of a balloon's tail where it leaves the box, in the side it leaves (at most)
// The dashes and the gaps, in strokes' widths. A dash's round ends reach half a width past it each side: a dash of 2
// shows 3 widths long, a gap of 3 shows 2. A dot is a dash of nothing: a round dot, a width across, a width apart.
EDIT_DASHED := [2]f32{2, 3}
EDIT_DOTTED := [2]f32{0, 2}
EDIT_TRIM_TOLERANCE :: 2     // how far a pixel's channel may be from the border's colour and still be trimmed (a JPEG's noise)

// A mouse pointer's outline, in a box of 11.5 x 18 (its tip at the top left): an arrow with a tail, the usual pointer's shape.
@(private = "file")
CURSOR_OUTLINE := [?]Edit_Vec{{0, 0}, {0, 16}, {4.2, 12.2}, {6.8, 18}, {9.2, 17}, {6.6, 11.4}, {11.5, 11.4}}
@(private = "file")
CURSOR_BOX :: Edit_Vec{11.5, 18}

// The mean colour of each cell of the picture (sRGB, row by row; owned).
Edit_Mosaic :: struct {
	cell:       int,   // picture pixels
	cols, rows: int,
	colors:     [][4]u8,
}

// A blurred copy of the picture, as a texture whose texel is `cell` picture pixels.
Edit_Blur :: struct {
	radius: int,   // picture pixels (edit_blur_px)
	cell:   int,
	tex:    render.Texture,
}

// A pasted picture's texture (Edit_Shape.image).
Edit_Image :: struct {
	id:   u32,
	tex:  render.Texture,
	size: [2]int,
}

// Where and how the document is painted.
Edit_Paint :: struct {
	doc:       ^Edit_Doc,
	picture:   render.Texture,
	mosaics:   []Edit_Mosaic,   // made so far: a pixelated box whose cell has none yet is a flat grey
	blurs:     []Edit_Blur,     // made so far: a blurred box whose radius has none yet is a flat grey
	images:    []Edit_Image,
	font_id:   font.Font_Id,
	font_bold: font.Font_Id,    // 0: font_id's
	fonts:     ^font.State,
	zoom:      f32,             // target pixels per picture pixel
	origin:    Edit_Vec,        // where the picture's top left is, target pixels
	skip:      int,             // the index of a shape not painted (the text being typed: its field shows it); -1 none
}

// `cancel` (atomic, may be nil): set from another thread, the work stops at the next row of cells (the result is partial).
edit_mosaic_make :: proc(rgba: []u8, size: [2]int, cell: int, cancel: ^bool = nil, allocator := context.allocator) -> Edit_Mosaic {
	c := max(cell, 1)
	m := Edit_Mosaic{cell = c, cols = (size.x + c - 1) / c, rows = (size.y + c - 1) / c}
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return {cell = c} }
	m.colors = make([][4]u8, m.cols * m.rows, allocator)
	sums := make([][4]u32, m.cols, context.temp_allocator)
	for gy in 0 ..< m.rows {
		if cancel != nil && sync.atomic_load(cancel) { break }
		for &s in sums { s = {} }
		y0, y1 := gy * c, min(gy * c + c, size.y)
		for y in y0 ..< y1 {
			row := rgba[y * size.x * 4:][:size.x * 4]
			for x in 0 ..< size.x {
				s := &sums[x / c]
				s[0] += u32(row[x * 4])
				s[1] += u32(row[x * 4 + 1])
				s[2] += u32(row[x * 4 + 2])
				s[3] += 1
			}
		}
		for gx in 0 ..< m.cols {
			s := sums[gx]
			if s[3] == 0 { continue }
			m.colors[gy * m.cols + gx] = {u8(s[0] / s[3]), u8(s[1] / s[3]), u8(s[2] / s[3]), 255}
		}
	}
	return m
}

edit_mosaic_free :: proc(m: ^Edit_Mosaic) {
	delete(m.colors)
	m^ = {}
}

// A blurred copy of the picture for a blur of `radius` picture pixels: RGBA of `out_size`, each pixel `cell` picture
// pixels (owned; nil when the picture is empty). `cancel` as edit_mosaic_make's (the copy is then partial).
edit_blur_make :: proc(rgba: []u8, size: [2]int, radius: int, cancel: ^bool = nil, allocator := context.allocator) -> (pixels: []u8, out_size: [2]int, cell: int) {
	cell = max(radius / EDIT_BLUR_DOWN, 1)
	mos := edit_mosaic_make(rgba, size, cell, cancel)
	defer edit_mosaic_free(&mos)
	if len(mos.colors) == 0 { return nil, {}, cell }
	small := pic.Image{pixels = slice.reinterpret([]u8, mos.colors), width = mos.cols, height = mos.rows}
	out := pic.blur(small, f32(radius) / f32(cell), allocator)
	return out.pixels, {out.width, out.height}, cell
}

// A colour of the model (0xRRGGBB, sRGB) for gt:draw.
edit_color :: proc(rgb: u32, alpha: f32 = 1) -> draw.Color {
	c := draw.hex(rgb << 8 | 0xFF)
	c.a = alpha
	return c
}

// Whether a light colour is under a step's number: it is written dark then.
@(private = "file")
color_light :: proc(rgb: u32) -> bool {
	r, g, b := f32((rgb >> 16) & 255), f32((rgb >> 8) & 255), f32(rgb & 255)
	return 0.299 * r + 0.587 * g + 0.114 * b > 160
}

@(private = "file")
target :: proc(p: ^Edit_Paint, v: Edit_Vec) -> Edit_Vec { return v * p.zoom + p.origin }

@(private = "file")
target_box :: proc(p: ^Edit_Paint, r: Edit_Box) -> draw.Rect { return {target(p, r.min), target(p, r.max)} }

// The picture, then the shapes in their order. (Circular corners: a rounded box filled and its dashes, a path, meet.)
edit_paint :: proc(dc: ^draw.Context, p: ^Edit_Paint) {
	circular := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, circular)
	draw.image(dc, p.picture, {p.origin, p.origin + p.doc.size * p.zoom})
	for &s, i in p.doc.shapes {
		if i != p.skip { edit_paint_shape(dc, p, &s) }
	}
}

// The picture taken (`rgba`, of `size`, not kept) through the operations, in order: the picture the shapes are on
// (owned; nil when an operation leaves nothing). It reads and writes every pixel: the window runs it on the chores.
edit_picture_make :: proc(rgba: []u8, size: [2]int, ops: []Edit_Op, allocator := context.allocator) -> (pixels: []u8, out_size: [2]int) {
	img := pic.Image{pixels = rgba, width = size.x, height = size.y}
	owned := false
	for op in ops {
		next: pic.Image
		switch op.kind {
		case .Rotate: next = pic.rotate(img, op.turns, allocator)
		case .Flip:   next = pic.flip(img, op.across, allocator)
		case .Resize: next = pic.resize(img, op.size.x, op.size.y, allocator = allocator)
		case .Canvas:
			m := op.margins
			next = pic.pad(img, m[0], m[1], m[2], m[3], pic.hex(op.color & 0xFFFFFF, u8(op.color >> 24)), allocator)
		case .Cut:    next = pic.cut_out(img, op.at, op.length, op.across, allocator)
		}
		if owned { delete(img.pixels, allocator) }
		img, owned = next, true
		if img.width <= 0 || img.height <= 0 { return nil, {} }
	}
	if !owned { img.pixels = slice.clone(rgba, allocator) }
	return img.pixels, {img.width, img.height}
}

// The mean colour around `box` (picture pixels) of the picture `rgba` of `size`, 0xAARRGGBB: a smart eraser's. It reads
// the pixels of the box's edge only, not of its inside: a few thousand at most.
edit_edge_color :: proc(rgba: []u8, size: [2]int, box: Edit_Box) -> u32 {
	img := pic.Image{pixels = rgba, width = size.x, height = size.y}
	x0, y0 := int(math.floor(box.min.x)), int(math.floor(box.min.y))
	x1, y1 := int(math.ceil(box.max.x)), int(math.ceil(box.max.y))
	c := pic.edge_mean(img, {x0, y0, max(x1 - x0, 1), max(y1 - y0, 1)})
	return u32(c[3]) << 24 | u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

// The part of the picture `rgba` of `size` that is not a border of one colour (auto crop); ok false: there is no such
// border, or the picture is of one colour. It reads every pixel: the window runs it on the chores.
edit_trim_box :: proc(rgba: []u8, size: [2]int) -> (box: Edit_Box, ok: bool) {
	r := pic.trim_bounds(pic.Image{pixels = rgba, width = size.x, height = size.y}, EDIT_TRIM_TOLERANCE)
	if r.w <= 0 || r.h <= 0 || (r.w == size.x && r.h == size.y) { return {}, false }
	return {{f32(r.x), f32(r.y)}, {f32(r.x + r.w), f32(r.y + r.h)}}, true
}

// A shape, with its shadow under it: the toolkit's drop shadow of a layer holding the shape alone.
edit_paint_shape :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	if s.style.shadow <= 0 || .Shadow not_in EDIT_PROPS[s.kind] {
		paint_body(dc, p, s)
		return
	}
	k := p.doc.scale * p.zoom
	soft := s.style.shadow * k
	filters := [1]draw.Filter{draw.filter_drop_shadow(Edit_Vec{1, 1} * (soft * EDIT_SHADOW_FALL), soft, EDIT_SHADOW_COLOR)}
	// (as far as the stroke, an arrow's head, a text's descent or the shadow's blur can reach)
	reach := edit_stroke_px(p.doc, s) * 4 + edit_text_px(p.doc, s) * 0.5 + s.style.shadow * p.doc.scale * 4
	bounds := target_box(p, edit_box_pad(edit_shape_box(p.doc, s), reach))
	if draw.push_effects(dc, bounds, {alpha = 1, filters = filters[:]}) { paint_body(dc, p, s) }
	draw.pop_layer(dc)
}

@(private = "file")
paint_body :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	doc := p.doc
	color := edit_color(s.style.color)
	w := max(edit_stroke_px(doc, s) * p.zoom, 1)
	fill, filled := fill_color(s.style)
	switch s.kind {
	case .Rectangle:
		r := target_box(p, edit_box_of(s.a, s.b))
		radius := min(s.style.radius * doc.scale * p.zoom, draw.rect_size(r).x * 0.5, draw.rect_size(r).y * 0.5)
		// (the stroke is centred on the box's edge, as a line's is on its path; the fill goes under it)
		if filled { draw.rect(dc, r, fill, radius) }
		if s.style.dash == .Solid {
			draw.rect(dc, draw.rect_pad(r, w * 0.5), color, radius > 0 ? radius + w * 0.5 : 0, w)
		} else {
			path := draw.path_make(allocator = context.temp_allocator)
			draw.path_rounded_rect(&path, r, radius)
			stroke(dc, &path, w, color, s.style.dash)
		}
	case .Ellipse:
		r := target_box(p, edit_box_of(s.a, s.b))
		path := draw.path_make(allocator = context.temp_allocator)
		draw.path_arc(&path, draw.rect_center(r), draw.rect_size(r) * 0.5, 0, 2 * math.PI)
		draw.path_close(&path)
		if filled { draw.path_fill(dc, &path, fill) }
		stroke(dc, &path, w, color, s.style.dash)
	case .Line:
		path := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&path, target(p, s.a))
		draw.path_line_to(&path, target(p, s.b))
		stroke(dc, &path, w, color, s.style.dash)
	case .Arrow:
		pts := [2]Edit_Vec{target(p, s.a), target(p, s.b)}
		paint_arrow(dc, pts[:], w, doc.scale * p.zoom, color, s.style.heads, s.style.dash)
	case .Pen:
		if len(s.points) == 0 { return }
		pts := make([]Edit_Vec, len(s.points), context.temp_allocator)
		for q, i in s.points { pts[i] = target(p, q) }
		paint_arrow(dc, pts, w, doc.scale * p.zoom, color, s.style.heads, s.style.dash)
	case .Text:
		paint_text(dc, p, s)
	case .Balloon:
		paint_balloon(dc, p, s)
	case .Highlighter:
		draw.rect(dc, target_box(p, edit_box_of(s.a, s.b)), edit_color(s.style.color, EDIT_HIGHLIGHT_ALPHA))
	case .Pixelate:
		paint_mosaic(dc, p, edit_box_of(s.a, s.b), edit_pixel_cell(doc, s.style))
	case .Blur:
		paint_blur(dc, p, edit_box_of(s.a, s.b), edit_blur_px(doc, s.style))
	case .Eraser:
		// (the colour around it, once the window read it: a grey box until then)
		c := draw.Color{0.5, 0.5, 0.5, 1}
		if s.sample >> 24 != 0 { c = edit_color(s.sample & 0xFFFFFF, f32(s.sample >> 24) / 255) }
		draw.rect(dc, target_box(p, edit_box_of(s.a, s.b)), c)
	case .Magnify:
		paint_magnify(dc, p, s)
	case .Step:
		paint_step(dc, p, s)
	case .Image:
		for img in p.images {
			if img.id == s.image { draw.image(dc, img.tex, target_box(p, edit_box_of(s.a, s.b))); break }
		}
	case .Cursor:
		paint_cursor(dc, target_box(p, edit_box_of(s.a, s.b)))
	case .Sticker:
		size := edit_text_px(doc, s) * p.zoom
		m := font.metrics(p.fonts, p.font_id, size)
		at := target(p, s.a)
		// (white: an emoji draws in its own colours; a glyph with none takes white)
		draw.text(dc, p.font_id, size, {at.x, at.y + m.ascent}, {1, 1, 1, 1}, s.text)
	}
}

// A path stroked whole, in dashes or in dots; their lengths grow with the width.
@(private = "file")
stroke :: proc(dc: ^draw.Context, path: ^draw.Path, w: f32, color: draw.Color, dash: Edit_Dash) {
	switch dash {
	case .Solid:
		draw.path_stroke(dc, path, w, color)
	case .Dashed, .Dotted:
		pattern := (dash == .Dashed ? EDIT_DASHED : EDIT_DOTTED) * w
		dashes := draw.path_dash(path, pattern[:], allocator = context.temp_allocator)
		draw.path_stroke(dc, &dashes, w, color)
	}
}

// A balloon: its box and tail as one outline, filled and stroked, then its text inside.
@(private = "file")
paint_balloon :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	doc := p.doc
	r := target_box(p, edit_box_of(s.a, s.b))
	radius := min(edit_text_px(doc, s) * p.zoom * EDIT_BALLOON_ROUND, draw.rect_size(r).x * 0.5, draw.rect_size(r).y * 0.5)
	path := draw.path_make(allocator = context.temp_allocator)
	balloon_outline(&path, r, radius, target(p, s.c))
	fill, filled := fill_color(s.style)
	if filled { draw.path_fill(dc, &path, fill) }
	if s.style.width > 0 { stroke(dc, &path, max(edit_stroke_px(doc, s) * p.zoom, 1), edit_color(s.style.color), s.style.dash) }
	paint_lines(dc, p, s, edit_text_origin(doc, s), edit_color(s.style.color))
}

// A rounded box `r` and a tail to `tip` as one closed contour, clockwise: the tail leaves the side that faces its tip,
// where the tip is across from it (clamped clear of the corners). A tip inside the box has no tail.
@(private = "file")
balloon_outline :: proc(path: ^draw.Path, r: draw.Rect, radius: f32, tip: Edit_Vec) {
	k := radius
	c := k * (1 - draw.PATH_KAPPA)
	// (the side the tail leaves: 0 top, 1 right, 2 bottom, 3 left; -1 none)
	side := -1
	switch {
	case tip.y > r.max.y: side = 2
	case tip.y < r.min.y: side = 0
	case tip.x > r.max.x: side = 1
	case tip.x < r.min.x: side = 3
	}
	// (where along that side its base is centred, and how wide)
	tail :: proc(path: ^draw.Path, from, to: f32, along: f32, k: f32, fixed: f32, tip: Edit_Vec, across: bool) {
		lo, hi := min(from, to), max(from, to)
		room := (hi - lo) - 2 * k
		if room <= 1 { return }
		half := min(room * EDIT_BALLOON_BASE, room) * 0.5
		centre := clamp(along, lo + k + half, hi - k - half)
		// (in the travel's direction: from `from` towards `to`)
		dir: f32 = to > from ? 1 : -1
		b0, b1 := centre - dir * half, centre + dir * half
		pt :: proc(v, fixed: f32, across: bool) -> Edit_Vec { return across ? Edit_Vec{v, fixed} : Edit_Vec{fixed, v} }
		draw.path_line_to(path, pt(b0, fixed, across))
		draw.path_line_to(path, tip)
		draw.path_line_to(path, pt(b1, fixed, across))
	}
	draw.path_move_to(path, {r.min.x + k, r.min.y})
	if side == 0 { tail(path, r.min.x, r.max.x, tip.x, k, r.min.y, tip, true) }
	draw.path_line_to(path, {r.max.x - k, r.min.y})
	if k > 0 { draw.path_cubic_to(path, {r.max.x - c, r.min.y}, {r.max.x, r.min.y + c}, {r.max.x, r.min.y + k}) }
	if side == 1 { tail(path, r.min.y, r.max.y, tip.y, k, r.max.x, tip, false) }
	draw.path_line_to(path, {r.max.x, r.max.y - k})
	if k > 0 { draw.path_cubic_to(path, {r.max.x, r.max.y - c}, {r.max.x - c, r.max.y}, {r.max.x - k, r.max.y}) }
	if side == 2 { tail(path, r.max.x, r.min.x, tip.x, k, r.max.y, tip, true) }
	draw.path_line_to(path, {r.min.x + k, r.max.y})
	if k > 0 { draw.path_cubic_to(path, {r.min.x + c, r.max.y}, {r.min.x, r.max.y - c}, {r.min.x, r.max.y - k}) }
	if side == 3 { tail(path, r.max.y, r.min.y, tip.y, k, r.min.x, tip, false) }
	draw.path_line_to(path, {r.min.x, r.min.y + k})
	if k > 0 { draw.path_cubic_to(path, {r.min.x, r.min.y + c}, {r.min.x + c, r.min.y}, {r.min.x + k, r.min.y}) }
	draw.path_close(path)
}

// The picture under a magnifier's box, `zoom` times larger around its centre, in a circle (an ellipse in a box not
// square) or a rectangle, and its edge. The picture alone: the shapes under it are not magnified.
@(private = "file")
paint_magnify :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	doc := p.doc
	box := edit_box_of(s.a, s.b)
	centre := (box.min + box.max) * 0.5
	half := edit_box_size(box) * 0.5 / max(s.style.zoom, 1)
	src := draw.Rect{centre - half, centre + half}
	r := target_box(p, box)
	w := max(edit_stroke_px(doc, s) * p.zoom, 1)
	color := edit_color(s.style.color)
	path := draw.path_make(allocator = context.temp_allocator)
	switch s.style.lens {
	case .Circle:
		draw.push_clip_ellipse(dc, draw.rect_center(r), draw.rect_size(r) * 0.5)
		draw.image(dc, p.picture, r, src)
		draw.pop_clip(dc)
		draw.path_arc(&path, draw.rect_center(r), draw.rect_size(r) * 0.5, 0, 2 * math.PI)
		draw.path_close(&path)
	case .Rectangle:
		draw.image(dc, p.picture, r, src)
		draw.path_rounded_rect(&path, r)
	}
	if s.style.width > 0 { stroke(dc, &path, w, color, s.style.dash) }
}

// A mouse pointer filling `r`: white, with a dark edge, as the system's.
@(private = "file")
paint_cursor :: proc(dc: ^draw.Context, r: draw.Rect) {
	k := draw.rect_size(r) / CURSOR_BOX
	path := draw.path_make(allocator = context.temp_allocator)
	for q, i in CURSOR_OUTLINE {
		v := r.min + q * k
		if i == 0 { draw.path_move_to(&path, v) } else { draw.path_line_to(&path, v) }
	}
	draw.path_close(&path)
	draw.path_fill(dc, &path, {1, 1, 1, 1})
	draw.path_stroke(dc, &path, max(min(k.x, k.y), 1), {0, 0, 0, 1})
}

// Black or white, whichever stands out from `rgb`: a text's outline or box when it has no fill colour.
@(private = "file")
color_against :: proc(rgb: u32) -> draw.Color {
	return color_light(rgb) ? draw.Color{0, 0, 0, 1} : draw.Color{1, 1, 1, 1}
}

// A style's fill colour with its opacity; ok false: none.
@(private = "file")
fill_color :: proc(style: Edit_Style) -> (c: draw.Color, ok: bool) {
	rgb := edit_fill(style) or_return
	return edit_color(rgb, f32(style.fill_color >> 24) / 255), true
}

// A text, line by line: its letters alone, with an outline (under them: the letters keep their shape), or on a box.
@(private = "file")
paint_text :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	doc := p.doc
	size := edit_text_px(doc, s) * p.zoom
	face := s.style.bold && p.font_bold != 0 ? p.font_bold : p.font_id
	color := edit_color(s.style.color)
	fill, filled := fill_color(s.style)
	other := filled ? fill : color_against(s.style.color)
	if s.style.text_look == .Background {
		draw.rect(dc, target_box(p, edit_shape_box(doc, s)), other, size * EDIT_TEXT_BOX_ROUND)
	}
	if s.style.text_look != .Outline {
		paint_lines(dc, p, s, s.a, color)
		return
	}
	m := font.metrics(p.fonts, face, size)
	at := target(p, s.a)
	y := at.y + m.ascent
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		sh := font.shape(p.fonts, face, size, line, {}, context.temp_allocator)
		draw.glyph_run_stroke(dc, size, {at.x, y}, other, sh.glyphs, size * EDIT_TEXT_OUTLINE)
		draw.glyph_run(dc, size, {at.x, y}, color, sh.glyphs)
		if nl < 0 { break }
		rest = rest[nl + 1:]
		y += m.line_height
	}
}

// A shape's text, line by line, from `origin` (its top left, picture pixels), in its size and weight.
@(private = "file")
paint_lines :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape, origin: Edit_Vec, color: draw.Color) {
	size := edit_text_px(p.doc, s) * p.zoom
	face := s.style.bold && p.font_bold != 0 ? p.font_bold : p.font_id
	m := font.metrics(p.fonts, face, size)
	at := target(p, origin)
	y := at.y + m.ascent
	rest := s.text
	for {
		nl := strings.index_byte(rest, '\n')
		draw.text(dc, face, size, {at.x, y}, color, nl < 0 ? rest : rest[:nl])
		if nl < 0 { break }
		rest = rest[nl + 1:]
		y += m.line_height
	}
}

// A line through `pts` (an arrow's two ends, a drawing's points), and a filled head at either end or both, that grows
// with the width (shortened on a short line). The line ends inside each head: its round end does not show past the
// head's back.
@(private = "file")
paint_arrow :: proc(dc: ^draw.Context, pts: []Edit_Vec, w, k: f32, color: draw.Color, heads: Edit_Heads, dash: Edit_Dash) {
	n := len(pts)
	if n == 0 { return }
	full: f32
	for i in 1 ..< n { full += vec_length(pts[i] - pts[i - 1]) }
	if n == 1 || full < 0.5 {
		draw.line(dc, pts[0], pts[n - 1], w, color)
		return
	}
	head := min(w * 4 + 4 * k, full)
	at_end := heads == .End || heads == .Both
	at_start := heads == .Start || heads == .Both
	if at_end && at_start { head = min(head, full * 0.5) }
	// (each head points along the line from where it is a head's length back: a drawing's last wiggle does not turn it)
	first, last := 0, n - 1
	end_dir, start_dir: Edit_Vec
	if at_end {
		j := n - 2
		for j > 0 && vec_length(pts[n - 1] - pts[j]) < head { j -= 1 }
		end_dir = vec_unit(pts[n - 1] - pts[j])
		last = j
	}
	if at_start {
		j := 1
		for j < n - 1 && vec_length(pts[0] - pts[j]) < head { j += 1 }
		start_dir = vec_unit(pts[0] - pts[j])
		first = j
	}
	path := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&path, at_start ? pts[0] - start_dir * (head * 0.5) : pts[0])
	// (the points under a head are left out; the ends are the two above and below)
	for i in first ..= last { if i > 0 && i < n - 1 { draw.path_line_to(&path, pts[i]) } }
	draw.path_line_to(&path, at_end ? pts[n - 1] - end_dir * (head * 0.5) : pts[n - 1])
	stroke(dc, &path, w, color, dash)
	if at_end { arrow_head(dc, pts[n - 1], end_dir, head, color) }
	if at_start { arrow_head(dc, pts[0], start_dir, head, color) }
}

// A filled head with its tip at `tip`, pointing along `dir`.
@(private = "file")
arrow_head :: proc(dc: ^draw.Context, tip, dir: Edit_Vec, head: f32, color: draw.Color) {
	n := Edit_Vec{-dir.y, dir.x}
	half := head * 0.6
	base := tip - dir * head
	path := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&path, tip)
	draw.path_line_to(&path, base + n * half)
	draw.path_line_to(&path, base - n * half)
	draw.path_close(&path)
	draw.path_fill(dc, &path, color)
}

@(private = "file")
vec_length :: proc(v: Edit_Vec) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }

@(private = "file")
vec_unit :: proc(v: Edit_Vec) -> Edit_Vec {
	l := vec_length(v)
	return l > 0 ? v / l : Edit_Vec{1, 0}
}

// A disc of the step's colour (of its fill colour, in a ring of its colour, when it has one) and its label.
@(private = "file")
paint_step :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	r := edit_step_radius(p.doc, s) * p.zoom
	c := target(p, s.a)
	fill, filled := fill_color(s.style)
	rgb, _ := edit_fill(s.style)
	disc := filled ? rgb : s.style.color   // (the label's ink stands out from it)
	draw.rect(dc, {c - r, c + r}, filled ? fill : edit_color(s.style.color), r)
	if filled { draw.rect(dc, {c - r, c + r}, edit_color(s.style.color), r, max(r * EDIT_STEP_RING, 1)) }
	size := edit_text_px(p.doc, s) * p.zoom * 0.8
	buf: [32]u8
	text := edit_step_label(buf[:], s.number, s.style.step_format)
	tw := font.text_width(p.fonts, p.font_id, size, text)
	if tw > r * EDIT_STEP_LABEL {
		size *= r * EDIT_STEP_LABEL / tw
		tw = r * EDIT_STEP_LABEL
	}
	m := font.metrics(p.fonts, p.font_id, size)
	draw.text(dc, p.font_id, size, {c.x - tw * 0.5, c.y + m.cap_height * 0.5}, color_against(disc), text)
}

// The box within the picture (a part outside it has nothing to hide); ok false: nothing of it is inside.
@(private = "file")
picture_cut :: proc(p: ^Edit_Paint, box: Edit_Box) -> (r: Edit_Box, ok: bool) {
	r = Edit_Box{{max(box.min.x, 0), max(box.min.y, 0)}, {min(box.max.x, p.doc.size.x), min(box.max.y, p.doc.size.y)}}
	return r, r.max.x > r.min.x && r.max.y > r.min.y
}

// The blurred copy of `radius` under the box, stretched back to the picture's pixels.
@(private = "file")
paint_blur :: proc(dc: ^draw.Context, p: ^Edit_Paint, box: Edit_Box, radius: int) {
	r, inside := picture_cut(p, box)
	if !inside { return }
	for b in p.blurs {
		if b.radius != radius || b.tex == 0 { continue }
		c := f32(b.cell)
		draw.image(dc, b.tex, target_box(p, r), {r.min / c, r.max / c})
		return
	}
	draw.rect(dc, target_box(p, r), {0.5, 0.5, 0.5, 1})
}

// The cells of the mosaic of `cell` that the box covers, each cut by the box.
@(private = "file")
paint_mosaic :: proc(dc: ^draw.Context, p: ^Edit_Paint, box: Edit_Box, cell_px: int) {
	r, inside := picture_cut(p, box)
	if !inside { return }
	m: ^Edit_Mosaic
	for &x in p.mosaics { if x.cell == cell_px && len(x.colors) > 0 { m = &x; break } }
	if m == nil {
		draw.rect(dc, target_box(p, r), {0.5, 0.5, 0.5, 1})
		return
	}
	c := f32(m.cell)
	x0, y0 := clamp(int(r.min.x / c), 0, m.cols - 1), clamp(int(r.min.y / c), 0, m.rows - 1)
	x1, y1 := clamp(int(math.ceil(r.max.x / c)), x0 + 1, m.cols), clamp(int(math.ceil(r.max.y / c)), y0 + 1, m.rows)
	// (each cell a hair larger on its right and bottom: no seam shows between two at a fractional zoom)
	seam := 0.5 / p.zoom
	for gy in y0 ..< y1 {
		for gx in x0 ..< x1 {
			cell := Edit_Box{{f32(gx) * c, f32(gy) * c}, {f32(gx + 1) * c + seam, f32(gy + 1) * c + seam}}
			cut := Edit_Box{{max(cell.min.x, r.min.x), max(cell.min.y, r.min.y)}, {min(cell.max.x, r.max.x), min(cell.max.y, r.max.y)}}
			if cut.max.x <= cut.min.x || cut.max.y <= cut.min.y { continue }
			v := m.colors[gy * m.cols + gx]
			draw.rect(dc, target_box(p, cut), draw.srgb(f32(v[0]) / 255, f32(v[1]) / 255, f32(v[2]) / 255))
		}
	}
}

////////////////////////////////
// The export

// What the flattened picture is for: the workflow (Done), the clipboard, a file (Save: the default folder; Save_As: the
// file chosen in the system's dialog), a host (Upload), a window over the others (Pin), paper (Print).
Edit_Export_Purpose :: enum u8 { Done, Copy, Save, Save_As, Upload, Pin, Print }

Edit_Tile :: struct {
	id:     render.Readback_Id,
	at:     [2]int,    // in the output
	size:   [2]int,
	pixels: []u8,      // once read (owned)
}

Edit_Export :: struct {
	purpose:  Edit_Export_Purpose,
	box:      [4]int,   // the part of the picture kept: x, y, w, h
	tiles:    [dynamic]Edit_Tile,
	due:      bool,     // the canvas' next draw records the tiles
	recorded: bool,
	failed:   bool,
}

// An export is asked for: the next frame of the editor draws it.
edit_export_begin :: proc(ex: ^Edit_Export, purpose: Edit_Export_Purpose, doc: ^Edit_Doc) {
	edit_export_free(ex)
	x, y, w, h := edit_output_box(doc)
	ex^ = {purpose = purpose, box = {x, y, w, h}, due = true}
}

edit_export_free :: proc(ex: ^Edit_Export) {
	for t in ex.tiles { delete(t.pixels) }
	delete(ex.tiles)
	ex^ = {}
}

// In a frame of the editor (a custom draw): the composition drawn into offscreen targets, their copies recorded.
// `paint` is the screen's: its place is changed here.
edit_export_record :: proc(dc: ^draw.Context, ex: ^Edit_Export, paint: Edit_Paint) {
	if !ex.due { return }
	ex.due = false
	ex.recorded = true
	p := paint
	p.zoom = 1
	p.skip = -1
	w, h := ex.box[2], ex.box[3]
	for ty := 0; ty < h; ty += EDIT_TILE {
		for tx := 0; tx < w; tx += EDIT_TILE {
			size := [2]int{min(EDIT_TILE, w - tx), min(EDIT_TILE, h - ty)}
			if !draw.offscreen_begin(dc, size) { ex.failed = true; return }
			p.origin = {-f32(ex.box[0] + tx), -f32(ex.box[1] + ty)}
			edit_paint(dc, &p)
			id := draw.offscreen_end(dc)
			if id == 0 { ex.failed = true; return }
			append(&ex.tiles, Edit_Tile{id = id, at = {tx, ty}, size = size})
		}
	}
}

// After a frame: the tiles read so far. Ready: `shot` is the picture (owned), at the size of the part kept.
edit_export_poll :: proc(r: ^render.Renderer, ex: ^Edit_Export, source: Source) -> (shot: Shot, status: render.Capture_Status) {
	if ex.failed { return {}, .Failed }
	if !ex.recorded { return {}, .Pending }
	waiting := false
	for &t in ex.tiles {
		if t.pixels != nil { continue }
		pixels, size, st := render.readback_poll(r, t.id)
		switch st {
		case .Ready:
			if size != t.size { delete(pixels); ex.failed = true; return {}, .Failed }
			t.pixels = pixels
		case .Failed:
			ex.failed = true
			return {}, .Failed
		case .Pending, .None:
			waiting = true
		}
	}
	if waiting { return {}, .Pending }
	w, h := ex.box[2], ex.box[3]
	shot.size = {w, h}
	shot.source = source
	if len(ex.tiles) == 1 {
		shot.rgba = ex.tiles[0].pixels
		ex.tiles[0].pixels = nil
	} else {
		// (a picture larger than a target: its tiles put together)
		shot.rgba = make([]u8, w * h * 4)
		for t in ex.tiles {
			for y in 0 ..< t.size.y {
				copy(shot.rgba[((t.at.y + y) * w + t.at.x) * 4:][:t.size.x * 4], t.pixels[y * t.size.x * 4:][:t.size.x * 4])
			}
		}
	}
	return shot, .Ready
}
