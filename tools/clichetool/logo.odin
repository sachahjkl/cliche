package clichetool

// logo: cliche's mark, drawn by the toolkit's paint package (the same bytes on every system). A silhouette on nothing:
// the four corners of a selection (what a region is), warm, around a lens (what takes the picture), dark with a ring
// and a highlight. Small sizes drop the ring and the highlight, which would blur (detail_for).
// assets/logo.png (1024 px), the sizes the program and the site embed, cliche.ico and .project/image.png: the toolkit's
// toolbox.write_logo writes them from logo_render.

import paint "gt:paint"
import toolbox "gt:toolbox"

LOGO_DIR    :: "assets"
LOGO_MASTER :: 1024
LOGO_ICO    :: "assets/cliche.ico"
@(rodata)
LOGO_SIZES  := [?]int{16, 32, 64, 128, 256}
// The drawing's own units: a square of LOGO_UNITS, scaled to the canvas.
LOGO_UNITS  :: 512.0
// The width of an edge, in units.
LOGO_EDGE   :: 10.0
// Small sizes are drawn from a master this many times larger, in one step of the cubic filter at most this factor.
LOGO_SHRINK_STEP :: 4

// The colours: top and bottom of each gradient, and the edges.
CORNER_TOP    :: 0xFF8A5B
CORNER_BOTTOM :: 0xE63E3A
CORNER_EDGE   :: 0xA82A2E
LENS_TOP      :: 0x3A3F5C
LENS_BOTTOM   :: 0x161827
LENS_EDGE     :: 0x0B0C14
RING_TOP      :: 0x8FA2FF
RING_BOTTOM   :: 0x4C5BD4
SHINE         :: 0xFFFFFF

// A shape with its gradient from `y0` to `y1` and an edge inside its outline.
@(private = "file")
shape :: proc(c: ^paint.Canvas, p: paint.Path, y0, y1: f32, top, bottom, edge: u32) {
	paint.fill(c, p, paint.linear({0, y0}, {0, y1}, paint.hex(top), paint.hex(bottom)))
	paint.set_clip(c, p)   // (the edge inside the outline only: the silhouette keeps its size)
	paint.stroke(c, p, {width = LOGO_EDGE * 2, join = .Round}, paint.solid(paint.hex(edge, 200)))
	paint.reset_clip(c)
}

// The top left corner of a selection, as one outline: its outer corner at (x, y), its bars `t` thick and `a` long, their
// ends round.
@(private = "file")
corner_path :: proc(p: ^paint.Path, x, y, t, a: f32) {
	R :: 40.0       // the outer corner's radius
	r := t * 0.35   // the inner corner's
	h := t / 2
	paint.move_to(p, x + R, y)
	paint.line_to(p, x + a - h, y)
	paint.quad_to(p, x + a, y, x + a, y + h)
	paint.quad_to(p, x + a, y + t, x + a - h, y + t)
	paint.line_to(p, x + t + r, y + t)
	paint.quad_to(p, x + t, y + t, x + t, y + t + r)
	paint.line_to(p, x + t, y + a - h)
	paint.quad_to(p, x + t, y + a, x + h, y + a)
	paint.quad_to(p, x, y + a, x, y + a - h)
	paint.line_to(p, x, y + R)
	paint.quad_to(p, x, y, x + R, y)
	paint.close(p)
}

// 1: everything (32 px and up); 0: the corners and a plain lens (16 to 24).
detail_for :: proc(size: int) -> int { return size <= 24 ? 0 : 1 }

logo_draw :: proc(size: int, detail: int) -> paint.Canvas {
	c := paint.canvas_make(size, size)
	k := f32(size) / LOGO_UNITS
	c.transform = paint.scale(paint.IDENTITY, k, k)

	// the four corners: one L each, round at its ends, turned a quarter for each; thicker when the picture is small
	t: f32 = detail == 0 ? 72 : 60
	a: f32 = detail == 0 ? 160 : 150
	for quarter in 0 ..< 4 {
		l: paint.Path
		defer paint.path_destroy(&l)
		corner_path(&l, 20, 20, t, a)
		paint.path_transform(&l, paint.rotate_at(paint.IDENTITY, f32(quarter) * 90, LOGO_UNITS / 2, LOGO_UNITS / 2))
		shape(&c, l, 0, LOGO_UNITS, CORNER_TOP, CORNER_BOTTOM, CORNER_EDGE)
	}

	// the lens: a dark disc, its glass ring, its highlight
	R: f32 = detail == 0 ? 118 : 112
	mid :: LOGO_UNITS / 2
	lens: paint.Path
	defer paint.path_destroy(&lens)
	paint.ellipse(&lens, mid - R, mid - R, 2 * R, 2 * R)
	shape(&c, lens, mid - R, mid + R, LENS_TOP, LENS_BOTTOM, LENS_EDGE)
	if detail > 0 {
		r := R * 0.62
		glass: paint.Path
		defer paint.path_destroy(&glass)
		paint.ellipse(&glass, mid - r, mid - r, 2 * r, 2 * r)
		paint.fill(&c, glass, paint.linear({0, mid - r}, {0, mid + r}, paint.hex(RING_TOP), paint.hex(RING_BOTTOM)))
		pupil: paint.Path
		defer paint.path_destroy(&pupil)
		p := r * 0.55
		paint.ellipse(&pupil, mid - p, mid - p, 2 * p, 2 * p)
		paint.fill(&c, pupil, paint.solid(paint.hex(LENS_BOTTOM)))
		shine: paint.Path
		defer paint.path_destroy(&shine)
		s := r * 0.26
		paint.ellipse(&shine, mid - r * 0.42 - s, mid - r * 0.42 - s, 2 * s, 2 * s)
		paint.fill(&c, shine, paint.solid(paint.hex(SHINE, 230)))
	}
	return c
}

// The picture at `size`: drawn large, then shrunk in steps the cubic filter keeps clean.
logo_render :: proc(size: int) -> paint.Canvas {
	n := size
	for n < LOGO_MASTER { n *= LOGO_SHRINK_STEP }
	c := logo_draw(n, detail_for(size))
	for n > size {
		next := max(n / LOGO_SHRINK_STEP, size)
		small := paint.resize(c, next, next)
		paint.canvas_destroy(&c)
		c, n = small, next
	}
	return c
}

logo :: proc() -> toolbox.Logo {
	return {
		render = proc(size: int, _: rawptr) -> paint.Canvas { return logo_render(size) },
		dir = LOGO_DIR, master = LOGO_MASTER, sizes = LOGO_SIZES[:], ico = LOGO_ICO, project_image = true,
	}
}
