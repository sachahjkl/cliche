package cliche

import "core:testing"

// A font of fixed width: half its size a character, its size and a fifth tall.
@(private = "file")
measure_fixed :: proc(user: rawptr, text: string, size: f32) -> Edit_Vec {
	return {f32(len(text)) * size * 0.5, size * 1.2}
}

// A model on a 1000 x 800 picture shown at 1:1 from the window's origin: window and picture pixels are the same.
@(private = "file")
model_make :: proc(m: ^Edit_Model) {
	edit_model_init(m, {1000, 800}, 1, measure_fixed, nil)
	m.view = {canvas = {{0, 0}, {1000, 800}}, zoom = 1}
}

@(private = "file")
drag :: proc(m: ^Edit_Model, from, to: Edit_Vec, shift := false) {
	edit_step(m, Edit_Press{at = from, button = .Left, shift = shift})
	edit_step(m, Edit_Move{at = (from + to) * 0.5, shift = shift})
	edit_step(m, Edit_Release{at = to, button = .Left, shift = shift})
}

@(test)
editor_draws_an_arrow_by_default :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	testing.expect_value(t, m.tool, Edit_Tool.Arrow)
	drag(&m, {100, 100}, {300, 200})
	testing.expect_value(t, len(m.doc.shapes), 1)
	s := m.doc.shapes[0]
	testing.expect_value(t, s.kind, Edit_Kind.Arrow)
	testing.expect_value(t, s.a, Edit_Vec{100, 100})
	testing.expect_value(t, s.b, Edit_Vec{300, 200})
	testing.expect_value(t, s.style, EDIT_STYLE_DEFAULT)
	testing.expect_value(t, m.doc.selected, 0)   // (drawn: selected, its handles shown)
	testing.expect(t, edit_idle(&m))
}

@(test)
editor_a_click_draws_nothing :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {101, 102})
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !edit_changed(&m))   // (no undo step for nothing)
}

@(test)
editor_shift_constrains :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Ellipse)
	drag(&m, {100, 100}, {300, 150}, shift = true)
	testing.expect_value(t, m.doc.shapes[0].b, Edit_Vec{300, 300})   // (a circle)
	edit_tool_set(&m, .Line)
	drag(&m, {0, 0}, {100, 10}, shift = true)
	b := m.doc.shapes[1].b
	testing.expect(t, abs(b.y) < 0.001)   // (flat: 6° snaps to 0°)
	testing.expect(t, abs(b.x - 100.4988) < 0.01)
}

@(test)
editor_hit_tests_strokes_and_fills :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	tol := f32(EDIT_HIT_PX)
	testing.expect_value(t, edit_hit(&m.doc, {100, 200}, tol), 0)   // (on its left side)
	testing.expect_value(t, edit_hit(&m.doc, {105, 200}, tol), 0)   // (near it)
	testing.expect_value(t, edit_hit(&m.doc, {200, 200}, tol), -1)  // (inside an outline: not it)
	m.doc.shapes[0].style.fill = true
	testing.expect_value(t, edit_hit(&m.doc, {200, 200}, tol), 0)
	// (the topmost first)
	edit_tool_set(&m, .Line)
	drag(&m, {50, 200}, {350, 200})
	testing.expect_value(t, edit_hit(&m.doc, {200, 202}, tol), 1)
	testing.expect_value(t, edit_hit(&m.doc, {200, 260}, tol), 0)
	testing.expect_value(t, edit_hit(&m.doc, {600, 600}, tol), -1)
}

@(test)
editor_select_moves_and_resizes :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {200, 200})
	edit_tool_set(&m, .Select)
	testing.expect_value(t, m.doc.selected, 0)   // (Select keeps the selection)
	drag(&m, {100, 130}, {150, 150})   // (on its left side, away from its handles: moved)
	s := m.doc.shapes[0]
	testing.expect_value(t, edit_box_of(s.a, s.b), Edit_Box{{150, 120}, {250, 220}})
	drag(&m, {250, 220}, {300, 300})   // (its bottom right handle)
	s = m.doc.shapes[0]
	testing.expect_value(t, edit_box_of(s.a, s.b), Edit_Box{{150, 120}, {300, 300}})
	edit_step(&m, Edit_Press{at = {600, 600}, button = .Left})   // (nothing there: no selection)
	edit_step(&m, Edit_Release{at = {600, 600}, button = .Left})
	testing.expect_value(t, m.doc.selected, -1)
	testing.expect_value(t, len(m.doc.history.undo), 3)   // (drawn, moved, resized)
}

@(test)
editor_undo_and_redo :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	drag(&m, {10, 200}, {100, 300})
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect(t, edit_delete(&m))
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect(t, edit_undo(&m))
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !edit_undo(&m))
	testing.expect(t, edit_redo(&m))
	testing.expect(t, edit_redo(&m))
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect_value(t, m.doc.shapes[1].a, Edit_Vec{10, 200})
	// (a new change drops what could be redone)
	drag(&m, {500, 500}, {600, 600})
	testing.expect(t, !edit_redo(&m))
}

@(test)
editor_step_numbers_count_up :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Step)
	drag(&m, {100, 100}, {100, 100})
	drag(&m, {300, 100}, {300, 100})
	drag(&m, {500, 100}, {520, 110})   // (a drag places it where the pointer is let go)
	testing.expect_value(t, len(m.doc.shapes), 3)
	testing.expect_value(t, m.doc.shapes[2].number, 3)
	testing.expect_value(t, m.doc.shapes[2].a, Edit_Vec{520, 110})
	testing.expect(t, edit_duplicate(&m))
	testing.expect_value(t, m.doc.shapes[3].number, 4)
	edit_delete(&m)
	testing.expect_value(t, edit_step_next(&m.doc), 4)
}

@(test)
editor_crop_is_clamped_and_undone :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Crop)
	drag(&m, {900, 700}, {1200, 1000})
	testing.expect(t, m.doc.has_crop)
	x, y, w, h := edit_output_box(&m.doc)
	testing.expect_value(t, [4]int{x, y, w, h}, [4]int{900, 700, 100, 100})
	testing.expect(t, edit_undo(&m))
	testing.expect(t, !m.doc.has_crop)
	x, y, w, h = edit_output_box(&m.doc)
	testing.expect_value(t, [4]int{x, y, w, h}, [4]int{0, 0, 1000, 800})
}

@(test)
editor_text_is_typed_and_given_up :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Text)
	edit_step(&m, Edit_Press{at = {100, 100}, button = .Left})
	_, typing := m.mode.(Edit_Typing)
	testing.expect(t, typing)
	edit_step(&m, Edit_Typed{text = "abcd"})
	edit_step(&m, Edit_Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect_value(t, m.doc.shapes[0].text, "abcd")
	b := m.doc.shapes[0].b   // (4 characters of 12 at 24 px)
	testing.expect(t, abs(b.x - 148) < 0.01 && abs(b.y - 128.8) < 0.01)
	testing.expect_value(t, len(m.doc.history.undo), 1)
	// (Escape gives back the text as it was; an empty new text is no text)
	edit_step(&m, Edit_Press{at = {110, 110}, button = .Left})
	edit_step(&m, Edit_Typed{text = "changed"})
	edit_step(&m, Edit_Type_End{keep = false})
	testing.expect_value(t, m.doc.shapes[0].text, "abcd")
	testing.expect_value(t, len(m.doc.history.undo), 1)
	edit_step(&m, Edit_Press{at = {500, 500}, button = .Left})
	edit_step(&m, Edit_Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect_value(t, len(m.doc.history.undo), 1)
}

@(test)
editor_property_changes_the_selection :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	style, props := edit_style_shown(&m)
	testing.expect(t, .Width in props && .Fill not_in props)
	style.color = EDIT_COLORS[4]
	testing.expect(t, edit_style_set(&m, style))
	testing.expect_value(t, m.doc.shapes[0].style.color, EDIT_COLORS[4])
	testing.expect_value(t, m.styles[.Arrow].color, EDIT_COLORS[4])   // (the next arrow too)
	testing.expect(t, edit_undo(&m))
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
}

// A slider runs through many widths: one undo step for them all, then a colour is a step of its own.
@(test)
editor_widths_in_a_row_are_one_step :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	style, _ := edit_style_shown(&m)
	for w in ([]f32{5, 9, 14, 17}) {
		style.width = w
		testing.expect(t, edit_style_set(&m, style))
	}
	testing.expect_value(t, len(m.doc.history.undo), 2)   // the arrow drawn, then its widths
	style.color = EDIT_COLORS[4]
	testing.expect(t, edit_style_set(&m, style))
	style.width = 3
	testing.expect(t, edit_style_set(&m, style))
	testing.expect_value(t, len(m.doc.history.undo), 4)   // (a width after a colour: a step again)
	testing.expect(t, edit_undo(&m))
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, m.doc.shapes[0].style.width, 17)
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, m.doc.shapes[0].style.width, EDIT_STYLE_DEFAULT.width)
}

@(test)
editor_zoom_keeps_the_point_under_the_pointer :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	at := Edit_Vec{400, 300}
	before := edit_to_picture(m.view, at)
	edit_step(&m, Edit_Wheel{at = at, delta = {0, -2}, zoom = true})
	testing.expect(t, m.view.zoom > 1.5)
	after := edit_to_picture(m.view, at)
	testing.expect(t, abs(after.x - before.x) < 0.01 && abs(after.y - before.y) < 0.01)
	edit_view_fit(&m)
	testing.expect(t, m.view.fit && abs(m.view.zoom - EDIT_FIT_MARGIN) < 0.0001)
}

@(test)
editor_mosaic_averages_its_cells :: proc(t: ^testing.T) {
	// (3 x 2 pixels, cells of 2: a full cell on the left, a half one on the right)
	rgba := []u8{
		0, 0, 0, 255,    100, 0, 0, 255,   7, 8, 9, 255,
		200, 0, 0, 255,  100, 40, 0, 255,  9, 8, 7, 255,
	}
	m := edit_mosaic_make(rgba, {3, 2}, 2)
	defer edit_mosaic_free(&m)
	testing.expect_value(t, [2]int{m.cols, m.rows}, [2]int{2, 1})
	testing.expect_value(t, m.colors[0], [4]u8{100, 10, 0, 255})
	testing.expect_value(t, m.colors[1], [4]u8{8, 8, 8, 255})
}

@(test)
editor_pans_with_the_middle_button :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_step(&m, Edit_Press{at = {100, 100}, button = .Middle})
	edit_step(&m, Edit_Move{at = {130, 90}})
	edit_step(&m, Edit_Release{at = {150, 80}, button = .Middle})
	testing.expect_value(t, m.view.offset, Edit_Vec{50, -20})
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !m.view.fit)
}

// The editor's last choices, as the preferences keep them, come back whole; a part not read leaves the default.
@(test)
the_choices_come_back :: proc(t: ^testing.T) {
	a: Edit_Model
	edit_model_init(&a, {100, 100}, 1, measure_fixed, nil)
	defer edit_model_destroy(&a)
	a.tool = .Rectangle
	a.styles[.Rectangle] = {color = 0x1E88E5, width = 7.5, shadow = 6, fill = true, text_size = 24}
	tool, styles := edit_choices_text(&a)
	b: Edit_Model
	edit_model_init(&b, {100, 100}, 1, measure_fixed, nil)
	defer edit_model_destroy(&b)
	edit_choices_read(&b, tool, styles)
	testing.expect_value(t, b.tool, Edit_Tool.Rectangle)
	testing.expect_value(t, b.styles, a.styles)
	c: Edit_Model
	edit_model_init(&c, {100, 100}, 1, measure_fixed, nil)
	defer edit_model_destroy(&c)
	edit_choices_read(&c, "Nothing", "Arrow zz 4 1 0 18;Pen 00ff00 3")
	testing.expect_value(t, c.tool, Edit_Tool.Arrow)
	testing.expect_value(t, c.styles[.Arrow], EDIT_STYLE_DEFAULT)
	testing.expect_value(t, c.styles[.Pen], EDIT_STYLE_DEFAULT)
}
