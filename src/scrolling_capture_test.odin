package cliche

import "core:slice"
import "core:testing"
import "core:time"
import pic "gt:image"

// A tall page seen through a window of `view` rows, which a fake wheel scrolls `rows_per_notch` rows a notch. Each row
// is unique, so a join at a wrong place shows in the picture.
@(private = "file")
Page :: struct {
	pixels:         []u8,
	width, height:  int,
	view:           int,
	rows_per_notch: int,
	offset:         int,    // the first row the page stands at
	before:         int,    // where it stood before the last turn
	lag:            int,    // captures after a turn that still show the old screen (a slow repaint)
	stale:          int,    // how many of those are left
	wheel_ok:       bool,
	wheels:         [dynamic]int,   // the turns asked (0, the probe, not kept)
	captures:       int,
	cancel_after:   int,    // the person presses Escape once this many screens are in (0: never)
	thumb:          int,    // columns at the right edge drawn as a scroll bar, its thumb where the offset says (0: none)
}

@(private = "file")
page_make :: proc(height, view, rows_per_notch: int) -> Page {
	width := 8
	p := Page{width = width, height = height, view = view, rows_per_notch = rows_per_notch, wheel_ok = true}
	p.pixels = make([]u8, width * height * 4)
	for y in 0 ..< height {
		for x in 0 ..< width {
			i := (y * width + x) * 4
			p.pixels[i], p.pixels[i + 1], p.pixels[i + 2], p.pixels[i + 3] = u8(y), u8(y >> 8), u8(x), 255
		}
	}
	return p
}

@(private = "file")
page_destroy :: proc(p: ^Page) {
	delete(p.pixels)
	delete(p.wheels)
}

// The fake capture: the rows the window shows now.
@(private = "file")
page_grab :: proc(user: rawptr) -> (shot: Shot, error: Flow_Error) {
	p := (^Page)(user)
	p.captures += 1
	at := p.offset
	if p.stale > 0 {
		p.stale -= 1
		at = p.before
	}
	stride := p.width * 4
	rgba := slice.clone(p.pixels[at * stride:][:p.view * stride])
	if p.thumb > 0 {
		// The bar does not scroll with the page: its track is the same on every screen, its thumb moves down a step.
		top := at * p.view / p.height
		size := max(p.view * p.view / p.height, 1)
		for y in 0 ..< p.view {
			shade: u8 = y >= top && y < top + size ? 200 : 60
			for x in p.width - p.thumb ..< p.width {
				i := (y * p.width + x) * 4
				rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = shade, shade, shade, 255
			}
		}
	}
	return {rgba = rgba, size = {p.width, p.view}, source = .Region, scale = 1}, .None
}

// The fake wheel: send_wheel's contract (0 notches turns nothing and says whether it can).
@(private = "file")
page_wheel :: proc(p: ^Page, notches: int) -> bool {
	if !p.wheel_ok { return false }
	if notches == 0 { return true }
	append(&p.wheels, notches)
	p.before = p.offset
	p.offset = clamp(p.offset + notches * p.rows_per_notch, 0, p.height - p.view)
	p.stale = p.lag
	return true
}

// Whether `img` is the page's first `rows` rows.
@(private = "file")
page_top :: proc(p: ^Page, img: pic.Image, rows: int) -> bool {
	stride := p.width * 4
	return img.width == p.width && img.height == rows && slice.equal(img.pixels, p.pixels[:rows * stride])
}

@(private = "file")
Driven :: struct {
	img:  pic.Image,   // the picture kept (none when dropped)
	kept: bool,
	why:  Scroll_End,
}

// The app's loop, with the page in place of the worker's capture and of send_wheel: each act of scroll_step is done at
// once, its answer stepped in.
@(private = "file")
drive :: proc(t: ^testing.T, p: ^Page, notches, max_frames: int, o := pic.Stitch_Options{}, bound := time.Duration(0)) -> (d: Driven) {
	run: Scroll_Run
	act, _ := scroll_step(&run, Scroll_Start{notches = notches, max_frames = max_frames, can_wheel = page_wheel(p, 0)})
	if act.kind == .Unavailable { return {why = .Unavailable} }
	testing.expect_value(t, act.kind, Scroll_Act_Kind.Choose)
	act, _ = scroll_step(&run, Scroll_Chosen{})
	st := pic.stitch_begin(o)
	last: []u8
	defer delete(last)
	for {
		switch act.kind {
		case .Capture:
			shot, err := scroll_settle(last, last == nil, bound, page_grab, p)
			if err != .None {
				act, _ = scroll_step(&run, Scroll_Frame{error = err})
				continue
			}
			_, result := pic.stitch_add(&st, {pixels = shot.rgba, width = shot.size.x, height = shot.size.y})
			delete(last)
			last = shot.rgba
			act, _ = scroll_step(&run, Scroll_Frame{result = result})
			if p.cancel_after > 0 && run.frames >= p.cancel_after {
				if next, ok := scroll_step(&run, Scroll_Cancel{}); ok { act = next }
			}
		case .Wheel:
			act, _ = scroll_step(&run, Scroll_Wheeled{page_wheel(p, act.notches)})
		case .Keep, .Drop:
			d.why = run.state.(Scroll_Ending).why
			img, ok := pic.stitch_end(&st)
			scroll_step(&run, Scroll_Ended{})
			testing.expect(t, !scroll_busy(&run), "Idle once the stitch ended")
			if act.kind == .Drop || !ok {
				pic.destroy(&img)
				return
			}
			d.img, d.kept = img, true
			return
		case .None, .Unavailable, .Choose:
			testing.fail_now(t, "no other act comes in the loop")
		}
	}
}

// The page ends: a turn that moves nothing gives a frame the stitcher calls Same, and the picture is the whole page.
@(test)
scrolling_stops_at_the_end_of_the_page :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	d := drive(t, &p, 3, 50)
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top(&p, d.img, 600), "the picture is the page")
	for n in p.wheels { testing.expect_value(t, n, 3) }
}

// The most screens: the run stops with that many, the page's top.
@(test)
scrolling_stops_at_the_limit :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	d := drive(t, &p, 3, 4)
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top(&p, d.img, 100 + 3 * 30), "four screens: the first, then three steps")
	testing.expect_value(t, len(p.wheels), 3)
}

// The stitcher's bound: Full ends the run with the rows up to it.
@(test)
scrolling_stops_when_full :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	d := drive(t, &p, 3, 50, {max_height = 250})
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top(&p, d.img, 250))
}

// A step of more than a screen: the run backs up to half the step once, keeps that step, and the page joins whole.
@(test)
scrolling_retries_a_smaller_step_once :: proc(t: ^testing.T) {
	p := page_make(600, 100, 40)   // (3 notches: 120 rows, more than the view)
	defer page_destroy(&p)
	d := drive(t, &p, 3, 50)
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top(&p, d.img, 600), "the picture is the page")
	testing.expect(t, len(p.wheels) > 2 && p.wheels[0] == 3 && p.wheels[1] == -2, "back by the difference to one notch")
	for n in p.wheels[2:] { testing.expect_value(t, n, 1) }

	// A smaller step that still moves more than a screen: no second retry; what was gathered is kept.
	q := page_make(600, 100, 120)
	defer page_destroy(&q)
	e := drive(t, &q, 3, 50)
	defer pic.destroy(&e.img)
	testing.expect(t, e.kept && e.why == .Done)
	testing.expect(t, page_top(&q, e.img, 100), "the first screen alone")
	testing.expect(t, slice.equal(q.wheels[:], []int{3, -2}), "one retry")

	// A step of one notch has nothing smaller to try.
	r := page_make(600, 100, 120)
	defer page_destroy(&r)
	f := drive(t, &r, 1, 50)
	defer pic.destroy(&f.img)
	testing.expect(t, f.kept && page_top(&r, f.img, 100))
	testing.expect(t, slice.equal(r.wheels[:], []int{1}), "no retry")
}

// Escape: the run drops what it gathered.
@(test)
scrolling_cancel_keeps_nothing :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	p.cancel_after = 3
	d := drive(t, &p, 3, 50)
	testing.expect(t, !d.kept && d.why == .Cancelled)

	// Escape while the worker takes a frame: its late frame means nothing, the end comes, then Idle.
	run: Scroll_Run
	scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = true})
	scroll_step(&run, Scroll_Chosen{})
	act, ok := scroll_step(&run, Scroll_Cancel{})
	testing.expect(t, ok && act.kind == .Drop)
	_, late := scroll_step(&run, Scroll_Frame{result = .Added})
	testing.expect(t, !late, "a frame after the cancel is refused")
	_, again := scroll_step(&run, Scroll_Cancel{})
	testing.expect(t, !again, "a second cancel means nothing")
	scroll_step(&run, Scroll_Ended{})
	testing.expect(t, !scroll_busy(&run))

	// Escape on the overlay: nothing was taken, nothing to end.
	run = {}
	scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = true})
	act, ok = scroll_step(&run, Scroll_Cancel{})
	testing.expect(t, ok && act.kind == .None && !scroll_busy(&run))
}

// The wheel cannot turn here (Wayland): said at the start, before any overlay or capture. Refused later, before a
// second screen: no picture either; after it: what was gathered is kept.
@(test)
scrolling_unavailable_where_the_wheel_cannot_turn :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	p.wheel_ok = false
	d := drive(t, &p, 3, 50)
	testing.expect(t, !d.kept && d.why == .Unavailable)
	testing.expect_value(t, p.captures, 0)

	run: Scroll_Run
	act, _ := scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = false})
	testing.expect(t, act.kind == .Unavailable && !scroll_busy(&run), "it stays Idle")

	scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = true})
	scroll_step(&run, Scroll_Chosen{})
	act, _ = scroll_step(&run, Scroll_Frame{result = .Added})
	testing.expect_value(t, act.kind, Scroll_Act_Kind.Wheel)
	act, _ = scroll_step(&run, Scroll_Wheeled{ok = false})
	testing.expect(t, act.kind == .Drop && run.state.(Scroll_Ending).why == .Unavailable)
	scroll_step(&run, Scroll_Ended{})

	scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = true})
	scroll_step(&run, Scroll_Chosen{})
	scroll_step(&run, Scroll_Frame{result = .Added})
	scroll_step(&run, Scroll_Wheeled{ok = true})
	scroll_step(&run, Scroll_Frame{result = .Added})
	act, _ = scroll_step(&run, Scroll_Wheeled{ok = false})
	testing.expect(t, act.kind == .Keep && run.state.(Scroll_Ending).why == .Done, "two screens are a picture")
}

// A page that repaints a capture late after each turn: the settle waits for it to move, so the old screen is not
// taken for the page's end. (With no wait the run would stop after the first screen.)
@(test)
scrolling_waits_for_the_page_to_move :: proc(t: ^testing.T) {
	p := page_make(300, 100, 10)
	defer page_destroy(&p)
	p.lag = 1
	d := drive(t, &p, 3, 50, bound = 300 * time.Millisecond)
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top(&p, d.img, 300), "the picture is the page")
}

// Whether `img` is the page's first `rows` rows, its `ignored` right columns aside (they hold the frames' scroll bar).
@(private = "file")
page_top_left :: proc(p: ^Page, img: pic.Image, rows, ignored: int) -> bool {
	if img.width != p.width || img.height != rows { return false }
	stride := p.width * 4
	compared := (p.width - ignored) * 4
	for y in 0 ..< rows {
		if !slice.equal(img.pixels[y * stride:][:compared], p.pixels[y * stride:][:compared]) { return false }
	}
	return true
}

// A scroll bar in the frames: its thumb moves at each step, so no row of one screen is a row of the next. With its
// columns left out of the comparison the page joins whole; without, every step fails to join, the smaller step too,
// and the run keeps the first screen.
@(test)
scrolling_leaves_the_scroll_bar_out :: proc(t: ^testing.T) {
	p := page_make(600, 100, 10)
	defer page_destroy(&p)
	p.thumb = 2
	d := drive(t, &p, 3, 50, {ignore_right = 2})
	defer pic.destroy(&d.img)
	testing.expect(t, d.kept && d.why == .Done)
	testing.expect(t, page_top_left(&p, d.img, 600, 2), "the page, joined left of the bar")

	q := page_make(600, 100, 10)
	defer page_destroy(&q)
	q.thumb = 2
	e := drive(t, &q, 3, 50)
	defer pic.destroy(&e.img)
	testing.expect(t, e.kept && e.why == .Done)
	testing.expect(t, page_top_left(&q, e.img, 100, 2), "the first screen alone")
	testing.expect(t, slice.equal(q.wheels[:], []int{3, -2}), "No_Overlap, the smaller step, No_Overlap again")
}

// The preference's logical pixels in the frame's pixels: rounded up, none for 0.
@(test)
scrolling_scroll_bar_in_frame_pixels :: proc(t: ^testing.T) {
	testing.expect_value(t, scroll_ignore_columns(20, 1), 20)
	testing.expect_value(t, scroll_ignore_columns(20, 1.5), 30)
	testing.expect_value(t, scroll_ignore_columns(17, 1.25), 22)   // (21.25: the column half covered counts)
	testing.expect_value(t, scroll_ignore_columns(0, 2), 0)
	testing.expect_value(t, scroll_ignore_columns(20, 0), 20)      // (a frame with no scale: 1)
}

// A capture that fails ends the run with nothing.
@(test)
scrolling_capture_failure_keeps_nothing :: proc(t: ^testing.T) {
	run: Scroll_Run
	scroll_step(&run, Scroll_Start{notches = 3, max_frames = 50, can_wheel = true})
	scroll_step(&run, Scroll_Chosen{})
	act, _ := scroll_step(&run, Scroll_Frame{error = .Gone})
	e := run.state.(Scroll_Ending)
	testing.expect(t, act.kind == .Drop && e.why == .Failed && e.error == .Gone)
}
