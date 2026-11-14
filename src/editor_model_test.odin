package cliche

import "core:strings"
import "core:testing"

// A font of fixed width: half its size a character (bold: three quarters), its size and a fifth tall.
@(private = "file")
measure_fixed :: proc(user: rawptr, text: string, size: f32, bold: bool) -> Edit_Vec {
	return {f32(len(text)) * size * (bold ? 0.75 : 0.5), size * 1.2}
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
	m.doc.shapes[0].style.fill_color = EDIT_OPAQUE | 0x1E88E5
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
	a.styles[.Rectangle] = {color = 0x1E88E5, fill_color = 0x80FDD835, width = 7.5, shadow = 6, text_size = 24, blur_radius = 8, pixel_size = 12}
	a.styles[.Text].text_look, a.styles[.Text].bold, a.styles[.Text].text_size = .Outline, true, 37.5
	a.styles[.Step].step_format = .Roman
	a.styles[.Blur].blur_radius = 32
	a.styles[.Pixelate].pixel_size = 6
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
	// (a broken style, a short one, one of the former six fields, a text look out of its enum: none is read)
	edit_choices_read(&c, "Nothing", "Arrow zz 4 1 0 18;Pen 00ff00 3;Line 1e88e5 4 3 0 24;Text e53935 4 3 00000000 24 7 0 0 8 12")
	testing.expect_value(t, c.tool, Edit_Tool.Arrow)
	testing.expect_value(t, c.styles[.Arrow], EDIT_STYLE_DEFAULT)
	testing.expect_value(t, c.styles[.Pen], EDIT_STYLE_DEFAULT)
	testing.expect_value(t, c.styles[.Line], EDIT_STYLE_DEFAULT)
	testing.expect_value(t, c.styles[.Text], EDIT_STYLE_DEFAULT)
}

@(test)
editor_zoom_to_a_step_keeps_the_centre :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_view_fit(&m)
	centre := edit_view_centre(&m)
	edit_view_zoom_to(&m, 2)
	testing.expect(t, abs(m.view.zoom - 2) < 0.0001 && !m.view.fit)
	after := edit_view_centre(&m)
	testing.expect(t, abs(after.x - centre.x) < 0.01 && abs(after.y - centre.y) < 0.01)
	edit_view_zoom_to(&m, 1)   // (Ctrl+1)
	testing.expect(t, abs(m.view.zoom - 1) < 0.0001)
}

// A fill colour of its own, with "none": a filled box is taken inside, an outline only on its edge.
@(test)
editor_fill_colour_is_its_own :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	_, filled := edit_fill(m.doc.shapes[0].style)
	testing.expect(t, !filled)
	style, props := edit_style_shown(&m)
	testing.expect(t, .Fill in props)
	style.fill_color = EDIT_OPAQUE | 0xFDD835
	testing.expect(t, edit_style_set(&m, style))
	rgb, has := edit_fill(m.doc.shapes[0].style)
	testing.expect(t, has && rgb == 0xFDD835)
	testing.expect_value(t, m.doc.shapes[0].style.color, EDIT_STYLE_DEFAULT.color)   // (the stroke keeps its colour)
	testing.expect_value(t, edit_hit(&m.doc, {200, 200}, EDIT_HIT_PX), 0)
	// (the picker's drag through fill colours: one undo step; alpha 0 is no fill)
	for c in ([]u32{0x80FDD835, 0x40FDD835, 0x00FDD835}) {
		style.fill_color = c
		testing.expect(t, edit_style_set(&m, style))
	}
	testing.expect_value(t, len(m.doc.history.undo), 2)   // the box drawn, then its fill
	testing.expect_value(t, edit_hit(&m.doc, {200, 200}, EDIT_HIT_PX), -1)
	testing.expect(t, edit_undo(&m))
	_, filled = edit_fill(m.doc.shapes[0].style)
	testing.expect(t, !filled)
}

// Shift+Enter's lines: as wide as the longest, as tall as all of them, an empty last one too; bold and a box measure again.
@(test)
editor_text_has_lines_and_looks :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Text)
	edit_step(&m, Edit_Press{at = {100, 100}, button = .Left})
	edit_step(&m, Edit_Typed{text = "ab\nlonger\n"})
	edit_step(&m, Edit_Type_End{keep = true})
	s := &m.doc.shapes[0]
	testing.expect_value(t, s.text, "ab\nlonger\n")
	// (6 characters of 12 at 24 px; 3 lines of 28.8)
	testing.expect(t, abs(s.b.x - 172) < 0.01 && abs(s.b.y - (100 + 3 * 28.8)) < 0.01)
	style, props := edit_style_shown(&m)
	testing.expect(t, .Bold in props && .Text_Look in props && .Fill in props)
	style.bold = true
	testing.expect(t, edit_style_set(&m, style))
	testing.expect(t, abs(m.doc.shapes[0].b.x - 208) < 0.01)   // (bold: 18 a character)
	style.text_look = .Background
	testing.expect(t, edit_style_set(&m, style))
	r := edit_shape_box(&m.doc, &m.doc.shapes[0])
	testing.expect(t, abs(r.min.x - (100 - 24 * EDIT_TEXT_BOX_PAD)) < 0.01)   // (the box reaches past the letters)
	testing.expect_value(t, len(m.doc.history.undo), 3)
	// (a text of blanks only is no text)
	edit_step(&m, Edit_Press{at = {600, 600}, button = .Left})
	edit_step(&m, Edit_Typed{text = " \n "})
	edit_step(&m, Edit_Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
}

@(test)
editor_step_labels :: proc(t: ^testing.T) {
	buf: [32]u8
	testing.expect_value(t, edit_step_label(buf[:], 12, .Number), "12")
	testing.expect_value(t, edit_step_label(buf[:], 3, .Lower), "c")
	testing.expect_value(t, edit_step_label(buf[:], 26, .Lower), "z")
	testing.expect_value(t, edit_step_label(buf[:], 27, .Lower), "aa")
	testing.expect_value(t, edit_step_label(buf[:], 28, .Upper), "AB")
	testing.expect_value(t, edit_step_label(buf[:], 4, .Roman), "iv")
	testing.expect_value(t, edit_step_label(buf[:], 1994, .Roman), "mcmxciv")
	testing.expect_value(t, edit_step_label(buf[:], 4000, .Roman), "4000")   // (past what Roman numerals write: digits)
	testing.expect_value(t, edit_step_label(buf[:], 0, .Upper), "0")
}

// The Step's number: with no step selected, where the next one starts; with one selected, its own (one undo step).
@(test)
editor_step_starts_where_asked :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Step)
	testing.expect_value(t, edit_step_number_shown(&m), 1)
	testing.expect(t, edit_step_number_set(&m, 5))
	testing.expect(t, !edit_changed(&m))   // (a start is no change of the picture)
	drag(&m, {100, 100}, {100, 100})
	testing.expect_value(t, m.doc.shapes[0].number, 5)
	testing.expect_value(t, edit_step_number_shown(&m), 5)   // (the step just placed is selected)
	edit_deselect(&m)
	testing.expect_value(t, edit_step_number_shown(&m), 6)
	m.doc.selected = 0
	testing.expect(t, edit_step_number_set(&m, 9))
	testing.expect_value(t, m.doc.shapes[0].number, 9)
	testing.expect_value(t, len(m.doc.history.undo), 2)
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, m.doc.shapes[0].number, 5)
	testing.expect(t, !edit_step_number_set(&m, 0))
}

// The scale handle: a text's size, a step's size, a drawing's points, by how far it goes along its diagonal.
@(test)
editor_scale_handle_scales :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Select)
	edit_add(&m, {kind = .Text, a = {100, 100}, text = strings.clone("abcd"), style = EDIT_STYLE_DEFAULT})
	at, has := edit_handles(&m.doc, &m.doc.shapes[0])
	testing.expect(t, has == {.Scale})
	testing.expect(t, abs(at[.Scale].x - 148) < 0.01 && abs(at[.Scale].y - 128.8) < 0.01)
	drag(&m, at[.Scale], at[.Scale] + {48, 28.8})   // (twice as far from its top left)
	s := m.doc.shapes[0]
	testing.expect(t, abs(s.style.text_size - 48) < 0.01)
	testing.expect_value(t, s.a, Edit_Vec{100, 100})
	testing.expect(t, abs(s.b.x - 196) < 0.01)   // (measured again)

	edit_add(&m, {kind = .Step, a = {500, 500}, b = {500, 500}, number = 1, style = EDIT_STYLE_DEFAULT})
	at, _ = edit_handles(&m.doc, &m.doc.shapes[1])
	r := edit_step_radius(&m.doc, &m.doc.shapes[1])
	drag(&m, at[.Scale], at[.Scale] - {r, r} * 0.5)   // (half way back to its centre)
	testing.expect(t, abs(m.doc.shapes[1].style.text_size - 12) < 0.01)
	testing.expect_value(t, m.doc.shapes[1].a, Edit_Vec{500, 500})

	pen := Edit_Shape{kind = .Pen, a = {0, 0}, b = {100, 50}, style = EDIT_STYLE_DEFAULT}
	append(&pen.points, Edit_Vec{0, 0}, Edit_Vec{50, 0}, Edit_Vec{100, 50})
	edit_add(&m, pen)
	at, _ = edit_handles(&m.doc, &m.doc.shapes[2])
	testing.expect_value(t, at[.Scale], Edit_Vec{100, 50})
	drag(&m, at[.Scale], {200, 100})
	p := m.doc.shapes[2].points
	testing.expect_value(t, p[1], Edit_Vec{100, 0})
	testing.expect_value(t, p[2], Edit_Vec{200, 100})
	testing.expect_value(t, len(m.doc.history.undo), 6)   // (three added, three scaled)
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, m.doc.shapes[2].points[2], Edit_Vec{100, 50})
}

// A right press on a shape selects it (the window opens its menu), with no undo step; elsewhere it means nothing.
@(test)
editor_right_press_selects :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	edit_deselect(&m)
	testing.expect(t, edit_step(&m, Edit_Press{at = {100, 200}, button = .Right}))
	testing.expect_value(t, m.doc.selected, 0)
	testing.expect(t, edit_idle(&m))
	testing.expect_value(t, len(m.doc.history.undo), 1)
	testing.expect(t, !edit_step(&m, Edit_Press{at = {700, 700}, button = .Right}))
	testing.expect_value(t, m.doc.selected, 0)
}

@(test)
editor_order_and_delete_all :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	drag(&m, {10, 200}, {100, 300})
	drag(&m, {10, 400}, {100, 500})
	m.doc.selected = 0
	testing.expect(t, !edit_can_order(&m, .Back) && !edit_can_order(&m, .Backward))
	testing.expect(t, edit_order(&m, .Front))
	testing.expect_value(t, m.doc.selected, 2)
	testing.expect_value(t, m.doc.shapes[2].a, Edit_Vec{10, 10})
	testing.expect(t, !edit_order(&m, .Forward))
	testing.expect(t, edit_order(&m, .Backward))
	testing.expect_value(t, m.doc.selected, 1)
	testing.expect_value(t, m.doc.shapes[1].a, Edit_Vec{10, 10})
	testing.expect(t, edit_order(&m, .Back))
	testing.expect_value(t, m.doc.shapes[0].a, Edit_Vec{10, 10})
	testing.expect(t, edit_undo(&m))
	testing.expect_value(t, m.doc.shapes[1].a, Edit_Vec{10, 10})
	testing.expect(t, edit_delete_all(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !edit_delete_all(&m))
	testing.expect(t, edit_undo(&m))   // (one step brings them all back)
	testing.expect_value(t, len(m.doc.shapes), 3)
}

// A text pasted: its line ends made "\n", the Text tool's style. A picture pasted: centred, made smaller to fit.
@(test)
editor_pastes_text_and_pictures :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	m.styles[.Text].color = 0x1E88E5
	testing.expect(t, edit_paste_text(&m, "one\r\ntwo\r\n", {50, 60}))
	s := m.doc.shapes[0]
	testing.expect_value(t, s.kind, Edit_Kind.Text)
	testing.expect_value(t, s.text, "one\ntwo")
	testing.expect_value(t, s.a, Edit_Vec{50, 60})
	testing.expect_value(t, s.style.color, u32(0x1E88E5))
	testing.expect(t, !edit_paste_text(&m, " \r\n", {0, 0}))
	testing.expect(t, edit_paste_image(&m, 7, {4000, 100}, {500, 400}))
	img := m.doc.shapes[1]
	testing.expect_value(t, img.kind, Edit_Kind.Image)
	testing.expect_value(t, img.image, u32(7))
	size := img.b - img.a
	testing.expect(t, abs(size.x - 900) < 0.01 && abs(size.y - 22.5) < 0.01)   // (900 of the picture's 1000)
	testing.expect(t, abs((img.a.x + img.b.x) * 0.5 - 500) < 0.01)
	testing.expect_value(t, m.doc.selected, 1)
	testing.expect_value(t, edit_hit(&m.doc, {500, 400}, 0), 1)
	testing.expect(t, !edit_paste_image(&m, 0, {10, 10}, {0, 0}))
	testing.expect_value(t, len(m.doc.history.undo), 2)
}

@(test)
editor_blur_draws_a_box :: proc(t: ^testing.T) {
	m: Edit_Model
	model_make(&m)
	defer edit_model_destroy(&m)
	edit_tool_set(&m, .Blur)
	drag(&m, {100, 100}, {101, 101})   // (a click: nothing)
	testing.expect_value(t, len(m.doc.shapes), 0)
	drag(&m, {100, 100}, {300, 200})
	s := m.doc.shapes[0]
	testing.expect_value(t, s.kind, Edit_Kind.Blur)
	testing.expect_value(t, edit_blur_px(&m.doc, s.style), 8)
	_, props := edit_style_shown(&m)
	testing.expect(t, props == {.Blur_Radius})
	edit_tool_set(&m, .Pixelate)
	_, props = edit_style_shown(&m)
	testing.expect(t, props == {.Pixel_Size})
	testing.expect_value(t, edit_pixel_cell(&m.doc, m.styles[.Pixelate]), 12)
}

// The blurred copy: a quarter of its radius a pixel, and soft (black meets white in greys).
@(test)
editor_blur_copy_is_small_and_soft :: proc(t: ^testing.T) {
	rgba := make([]u8, 32 * 2 * 4)
	defer delete(rgba)
	for y in 0 ..< 2 {
		for x in 0 ..< 32 {
			v := u8(x < 16 ? 0 : 255)
			copy(rgba[(y * 32 + x) * 4:], []u8{v, v, v, 255})
		}
	}
	pixels, size, cell := edit_blur_make(rgba, {32, 2}, 8)
	defer delete(pixels)
	testing.expect_value(t, cell, 2)
	testing.expect_value(t, size, [2]int{16, 1})
	testing.expect(t, pixels[0] < pixels[15 * 4])
	middle := pixels[8 * 4]
	testing.expect(t, middle > 20 && middle < 235)
}

////////////////////////////////
// The editor's outputs: Save as, the files dropped, the pins

// Save as: the extension typed decides the format; with none, the filter chosen does and its extension is added.
@(test)
save_as_takes_the_format_typed_else_the_filter :: proc(t: ^testing.T) {
	path, format := save_as_choice("/home/a/shot.JPG", 0)
	testing.expect(t, path == "/home/a/shot.JPG" && format == .Jpeg, "the extension typed wins over the PNG filter")
	path, format = save_as_choice("/home/a/shot.webp", 1)
	testing.expect(t, path == "/home/a/shot.webp" && format == .Webp, ".webp")
	path, format = save_as_choice("/home/a/shot", 1)
	testing.expect(t, path == "/home/a/shot.jpg" && format == .Jpeg, "no extension: the filter's, added")
	path, format = save_as_choice("/home/a.b/shot", 2)
	testing.expect(t, path == "/home/a.b/shot.webp" && format == .Webp, "a dot of a folder is not an extension")
	path, format = save_as_choice("/home/a/notes.txt", 0)
	testing.expect(t, path == "/home/a/notes.txt" && format == .Png_Small, "another extension: kept, the filter's format")
	_, format = save_as_choice("/home/a/x", 99)
	testing.expect_value(t, format, Save_Format.Webp)
}

// The format kept in save.as_format reads back; a word it does not know is PNG.
@(test)
save_as_format_names_read_back :: proc(t: ^testing.T) {
	for f, i in SAVE_AS_FORMATS {
		testing.expect_value(t, save_as_format_named(SAVE_AS_NAMES[i]), f)
		testing.expect_value(t, save_as_index(f), i)
	}
	testing.expect_value(t, save_as_format_named("gif"), Save_Format.Png_Small)
	testing.expect_value(t, save_as_index(.Webp_Lossless), 0)
}

// A drop opens its pictures, each in an editor, at most EDITOR_DROP_MOST; the rest is said to be left out.
@(test)
a_drop_opens_its_pictures :: proc(t: ^testing.T) {
	testing.expect(t, picture_file("/a/b.PNG") && picture_file("C:\\a\\b.jpeg") && picture_file("/a/b.webp") && picture_file("/a/b.bmp"))
	testing.expect(t, !picture_file("/a/b.txt") && !picture_file("/a.png/b") && !picture_file("/a/png"))
	open, left_out := drop_pictures([]string{"/a/1.png", "/a/notes.txt", "/a/2.jpg"})
	testing.expect(t, len(open) == 2 && open[0] == "/a/1.png" && open[1] == "/a/2.jpg" && left_out)
	many: [EDITOR_DROP_MOST + 2]string
	for &m in many { m = "/a/x.png" }
	open, left_out = drop_pictures(many[:])
	testing.expect(t, len(open) == EDITOR_DROP_MOST && left_out, "past the most: left out")
	open, left_out = drop_pictures([]string{"/a/1.png"})
	testing.expect(t, len(open) == 1 && !left_out)
}

// A pin first shows as large as on its screen, centred; a picture larger than the output is made smaller.
@(test)
a_pin_first_shows_centred :: proc(t: ^testing.T) {
	p := pin_place_first({400, 200}, 2, {1920, 1080})
	testing.expect_value(t, p.zoom, f32(1))
	testing.expect_value(t, pin_size({400, 200}, 2, p.zoom), [2]f32{200, 100})
	testing.expect_value(t, p.at, [2]f32{860, 490})
	big := pin_place_first({3840, 2160}, 1, {1920, 1080})
	size := pin_size({3840, 2160}, 1, big.zoom)
	testing.expect(t, size.x <= 1920 * PIN_FIRST_MOST + 0.01 && size.y <= 1080 * PIN_FIRST_MOST + 0.01, "within the output")
	testing.expect(t, big.at.x >= 0 && big.at.y >= 0, "on it")
}

// The wheel zooms around the pointer: the point under it stays; the zoom has its bounds.
@(test)
a_pin_zooms_around_the_pointer :: proc(t: ^testing.T) {
	p := Pin_Place{at = {100, 100}, zoom = 1}
	pointer := [2]f32{150, 120}
	before := (pointer - p.at) / p.zoom   // (the picture's point under the pointer)
	z := pin_zoom_at(p, pointer, 3)
	testing.expect(t, z.zoom > 1)
	after := (pointer - z.at) / z.zoom
	testing.expect(t, abs(after.x - before.x) < 0.001 && abs(after.y - before.y) < 0.001, "the same point under the pointer")
	far := pin_zoom_at(p, pointer, 1000)
	testing.expect_value(t, far.zoom, f32(PIN_ZOOM_MAX))
	near := pin_zoom_at(p, pointer, -1000)
	testing.expect_value(t, near.zoom, f32(PIN_ZOOM_MIN))
}

// A drag moves the picture with the pointer, and never past where PIN_KEEP_PX of it stays on the output.
@(test)
a_pin_drag_keeps_it_on_the_output :: proc(t: ^testing.T) {
	p := Pin_Place{at = {100, 100}, zoom = 1}
	window := [2]f32{800, 600}
	moved := pin_drag_to(p, {200, 100}, 1, {300, 250}, {10, 10}, window)
	testing.expect_value(t, moved.at, [2]f32{290, 240})
	gone := pin_drag_to(p, {200, 100}, 1, {5000, -5000}, {10, 10}, window)
	testing.expect_value(t, gone.at, [2]f32{800 - PIN_KEEP_PX, PIN_KEEP_PX - 100})
	left := pin_drag_to(p, {200, 100}, 1, {-5000, 5000}, {10, 10}, window)
	testing.expect_value(t, left.at, [2]f32{PIN_KEEP_PX - 200, 600 - PIN_KEEP_PX})
}

// The input region covers the picture, its edges rounded outwards.
@(test)
a_pin_takes_the_pointer_on_its_picture :: proc(t: ^testing.T) {
	r := pin_input_rect({at = {10.5, 20.25}, zoom = 0.5}, {101, 41}, 1)
	testing.expect_value(t, r, [4]int{10, 20, 51, 21})
}
