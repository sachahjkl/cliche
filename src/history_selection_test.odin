package cliche

// The history's selection is the toolkit's Item_Selection, the grid's and the list's: the grid's keys go by columns,
// the acts on entries take every entry selected, the acts on one picture the cursor's.

import "core:testing"
import "gt:ui"

@(test)
the_grid_moves_by_columns :: proc(t: ^testing.T) {
	// (10 cells, 4 a line, a page of 8)
	testing.expect_value(t, history_grid_target(-1, 10, 4, 8, .Right), 0)   // (no cursor: the first cell)
	testing.expect_value(t, history_grid_target(1, 10, 4, 8, .Down), 5)
	testing.expect_value(t, history_grid_target(1, 10, 4, 8, .Up), 0)        // (clamped)
	testing.expect_value(t, history_grid_target(5, 10, 4, 8, .Left), 4)
	testing.expect_value(t, history_grid_target(5, 10, 4, 8, .Page_Down), 9)
	testing.expect_value(t, history_grid_target(5, 10, 4, 8, .Home), 0)
	testing.expect_value(t, history_grid_target(5, 10, 4, 8, .End), 9)
	testing.expect_value(t, history_grid_target(0, 0, 4, 8, .Down), -1)
}

@(test)
the_acts_take_every_entry_selected :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	hw := &app.history_window
	defer {
		history_destroy(&hw.history)
		delete(hw.shown)
		delete(hw.shown_ids)
		ui.table_destroy(&hw.table)
	}
	hw.table.vl.multi = true
	hw.mode_built = .Grid
	for i in 0 ..< 5 {
		id := u64(10 + i)
		history_add(&hw.history, {id = id, time_ms = i64(1000 * (i + 1)), kind = .Region, path = i == 4 ? "" : "/p/a.png"}, 100)
		append(&hw.shown, i)
		append(&hw.shown_ids, id)
	}
	sel := history_selection(hw)
	rows := history_rows(app)

	// a click, then Shift and Down by a line of 2: the range from the anchor, in the order shown
	ui.item_selection_click(sel, rows, 0, {})
	ui.item_selection_move(sel, rows, history_grid_target(sel.sel, rows.count, 2, 4, .Down), {.Shift})
	got := history_selected(app)
	testing.expect(t, len(got) == 3 && got[0] == 10 && got[1] == 11 && got[2] == 12, "the range of three")
	testing.expect_value(t, history_cursor(app), u64(12))
	enabled := history_enabled(app)
	testing.expect(t, .Remove in enabled && .Combine_Side in enabled, "Remove and Combine act on several")
	testing.expect(t, .Edit in enabled, "Edit: the cursor's picture")

	// Ctrl: the cursor alone moves to the entry with no file; Edit follows it, the acts keep the three
	ui.item_selection_move(sel, rows, 4, {.Ctrl})
	testing.expect_value(t, len(history_selected(app)), 3)
	testing.expect(t, .Edit not_in history_enabled(app), "Edit: the cursor's entry has no picture")

	// Escape on several: the cursor's alone
	testing.expect(t, ui.item_selection_escape(sel, rows))
	got = history_selected(app)
	testing.expect(t, len(got) == 1 && got[0] == 14, "the cursor's entry alone")
	testing.expect(t, !ui.item_selection_escape(sel, rows), "one entry: Escape is the window's")

	// a filter hides some: they leave the selection, the cursor finds its entry again
	ui.item_selection_all(sel, rows)
	resize(&hw.shown_ids, 2)
	hw.shown_ids[0], hw.shown_ids[1] = 12, 14
	resize(&hw.shown, 2)
	hw.shown[0], hw.shown[1] = 2, 4
	hw.rows_due, hw.cursor_due, hw.cursor_id = true, true, 14
	history_rows_settle(app)
	testing.expect_value(t, len(sel.selected), 2)
	testing.expect_value(t, history_cursor(app), u64(14))
}
