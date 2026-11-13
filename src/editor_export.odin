package cliche

// The editor's picture, drawn: on the screen (editor.odin, at the view's zoom) and flattened for the after-capture chain
// (here, at the picture's own size). One procedure paints both, so the file looks as the canvas did.
//
// Flattening draws the composition into offscreen targets (gt:draw's offscreen_begin, at most EDIT_TILE pixels a side:
// a target larger than the device allows is refused) during a frame of the editor's window, and reads them back
// (render.readback_poll) a frame or two later. The renderer converts what it reads to straight RGBA; a picture of
// several tiles is put together here, once.
//
// Pixelate draws a mosaic: the picture's mean colour by cells of EDIT_PIXELATE_CELL logical pixels, on one grid for the
// whole picture. A thread of the editor's makes it once per picture (edit_mosaic_make goes through every pixel).

import "core:math"
import "core:sync"
import "gt:draw"
import "gt:font"
import "gt:render"

EDIT_TILE          :: 4096   // the side of an offscreen target of the export, at most
EDIT_PIXELATE_CELL :: 12     // logical pixels
EDIT_SHADOW_FALL   :: 0.8    // how far the shadow falls down and right, per pixel of its softness (Edit_Style.shadow)
EDIT_SHADOW_COLOR  :: draw.Color{0, 0, 0, 0.6}

// The mean colour of each cell of the picture (sRGB, row by row; owned).
Edit_Mosaic :: struct {
	cell:       int,   // picture pixels
	cols, rows: int,
	colors:     [][4]u8,
}

// Where and how the document is painted.
Edit_Paint :: struct {
	doc:     ^Edit_Doc,
	picture: render.Texture,
	mosaic:  ^Edit_Mosaic,   // nil: not made yet (a pixelated box is a flat grey meanwhile)
	font_id: font.Font_Id,
	fonts:   ^font.State,
	zoom:    f32,            // target pixels per picture pixel
	origin:  Edit_Vec,       // where the picture's top left is, target pixels
	skip:    int,            // the index of a shape not painted (the text being typed: its field shows it); -1 none
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

// The picture, then the shapes in their order.
edit_paint :: proc(dc: ^draw.Context, p: ^Edit_Paint) {
	draw.image(dc, p.picture, {p.origin, p.origin + p.doc.size * p.zoom})
	for &s, i in p.doc.shapes {
		if i != p.skip { edit_paint_shape(dc, p, &s) }
	}
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
	switch s.kind {
	case .Rectangle:
		r := target_box(p, edit_box_of(s.a, s.b))
		// (the stroke is centred on the box's edge, as a line's is on its path)
		outer := draw.rect_pad(r, w * 0.5)
		if s.style.fill { draw.rect(dc, outer, color) } else { draw.rect(dc, outer, color, 0, w) }
	case .Ellipse:
		r := target_box(p, edit_box_of(s.a, s.b))
		centre := draw.rect_center(r)
		radii := draw.rect_size(r) * 0.5
		path := draw.path_make(allocator = context.temp_allocator)
		if s.style.fill {
			draw.path_arc(&path, centre, radii + w * 0.5, 0, 2 * math.PI)
			draw.path_close(&path)
			draw.path_fill(dc, &path, color)
		} else {
			draw.path_arc(&path, centre, radii, 0, 2 * math.PI)
			draw.path_close(&path)
			draw.path_stroke(dc, &path, w, color)
		}
	case .Line:
		draw.line(dc, target(p, s.a), target(p, s.b), w, color)
	case .Arrow:
		paint_arrow(dc, target(p, s.a), target(p, s.b), w, doc.scale * p.zoom, color)
	case .Pen:
		if len(s.points) == 0 { return }
		if len(s.points) == 1 {
			q := target(p, s.points[0])
			draw.line(dc, q, q, w, color)
			return
		}
		path := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&path, target(p, s.points[0]))
		for q in s.points[1:] { draw.path_line_to(&path, target(p, q)) }
		draw.path_stroke(dc, &path, w, color)
	case .Text:
		size := edit_text_px(doc, s) * p.zoom
		m := font.metrics(p.fonts, p.font_id, size)
		at := target(p, s.a)
		draw.text(dc, p.font_id, size, {at.x, at.y + m.ascent}, color, s.text)
	case .Highlighter:
		draw.rect(dc, target_box(p, edit_box_of(s.a, s.b)), edit_color(s.style.color, EDIT_HIGHLIGHT_ALPHA))
	case .Pixelate:
		paint_mosaic(dc, p, edit_box_of(s.a, s.b))
	case .Step:
		paint_step(dc, p, s)
	}
}

// A line and a filled head that grows with the width (shortened with a short arrow).
@(private = "file")
paint_arrow :: proc(dc: ^draw.Context, a, b: Edit_Vec, w, k: f32, color: draw.Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.5 {
		draw.line(dc, a, b, w, color)
		return
	}
	dir := d / l
	n := Edit_Vec{-dir.y, dir.x}
	head := min(w * 4 + 4 * k, l)
	half := head * 0.6
	base := b - dir * head
	// (the shaft ends inside the head: its round end does not show past the head's back)
	draw.line(dc, a, b - dir * (head * 0.5), w, color)
	path := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&path, b)
	draw.path_line_to(&path, base + n * half)
	draw.path_line_to(&path, base - n * half)
	draw.path_close(&path)
	draw.path_fill(dc, &path, color)
}

@(private = "file")
paint_step :: proc(dc: ^draw.Context, p: ^Edit_Paint, s: ^Edit_Shape) {
	r := edit_step_radius(p.doc, s) * p.zoom
	c := target(p, s.a)
	draw.rect(dc, {c - r, c + r}, edit_color(s.style.color), r)
	size := edit_text_px(p.doc, s) * p.zoom * 0.8
	buf: [24]u8
	text := int_text(buf[:], s.number)
	m := font.metrics(p.fonts, p.font_id, size)
	tw := font.text_width(p.fonts, p.font_id, size, text)
	ink := color_light(s.style.color) ? draw.Color{0, 0, 0, 1} : draw.Color{1, 1, 1, 1}
	draw.text(dc, p.font_id, size, {c.x - tw * 0.5, c.y + m.cap_height * 0.5}, ink, text)
}

// The cells of the mosaic that the box covers, each cut by the box.
@(private = "file")
paint_mosaic :: proc(dc: ^draw.Context, p: ^Edit_Paint, box: Edit_Box) {
	r := Edit_Box{{max(box.min.x, 0), max(box.min.y, 0)}, {min(box.max.x, p.doc.size.x), min(box.max.y, p.doc.size.y)}}
	if r.max.x <= r.min.x || r.max.y <= r.min.y { return }
	m := p.mosaic
	if m == nil || len(m.colors) == 0 {
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

// The decimal text of `n` in `buf`.
@(private = "file")
int_text :: proc(buf: []u8, n: int) -> string {
	i := len(buf)
	v := abs(n)
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 || i == 1 { break }
	}
	if n < 0 { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

////////////////////////////////
// The export

// What the flattened picture is for.
Edit_Export_Purpose :: enum u8 { Done, Copy, Save }

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
