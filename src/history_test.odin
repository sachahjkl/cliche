package cliche

import "core:strings"
import "core:testing"

@(private = "file")
entry :: proc(id: u64, time_ms: i64, kind: History_Kind, path := "", url := "", text := "", bytes: i64 = 0) -> History_Entry {
	return {id = id, time_ms = time_ms, kind = kind, path = path, url = url, text = text, bytes = bytes}
}

@(private = "file")
sample :: proc(h: ^History) {
	history_add(h, entry(1, 1000, .Region, path = "/p/cliche-a.png", bytes = 300), 100)
	history_add(h, entry(2, 2000, .Video, path = "/p/cliche-b.mp4", bytes = 9000), 100)
	history_add(h, entry(3, 3000, .Qr, text = "https://example.org/menu"), 100)
	history_add(h, entry(4, 4000, .Screen, path = "/p/Desk.png", url = "https://host/x.png", bytes = 100), 100)
	history_add(h, entry(5, 5000, .Text, text = "Hello\nworld,  the text\tread"), 100)
}

@(private = "file")
ids_of :: proc(h: ^History, places: []int) -> []u64 {
	out := make([]u64, len(places), context.temp_allocator)
	for p, i in places { out[i] = h.entries[p].id }
	return out
}

@(test)
the_oldest_go_beyond_the_cap :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	for i in 1 ..= 5 { history_add(&h, entry(u64(i), i64(i), .Region), 3) }
	testing.expect_value(t, len(h.entries), 3)
	testing.expect_value(t, h.entries[0].id, 3)
	testing.expect(t, history_find(&h, 1) == nil)
	testing.expect_value(t, history_find(&h, 5).id, 5)
	// (an id given twice is refused: the worker and the interface name an entry the same way)
	testing.expect(t, !history_add(&h, entry(5, 9, .Region), 3))
	history_trim(&h, 1)
	testing.expect_value(t, len(h.entries), 1)
	testing.expect_value(t, history_find(&h, 5).id, 5)
}

@(test)
ids_grow_and_follow_the_clock :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	a := history_new_id(&h, 1000)
	b := history_new_id(&h, 1000)
	c := history_new_id(&h, 999)
	testing.expect(t, a < b && b < c, "the ids grow even when the clock does not")
	testing.expect(t, a >= 1000 << 8)
}

@(test)
removed_entries_leave_the_index :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	sample(&h)
	testing.expect_value(t, history_remove(&h, {2, 4, 99}), 2)
	testing.expect_value(t, len(h.entries), 3)
	testing.expect(t, history_find(&h, 2) == nil)
	testing.expect_value(t, history_find(&h, 5).kind, History_Kind.Text)
	testing.expect_value(t, history_remove(&h, {99}), 0)
}

@(test)
the_search_finds_names_texts_addresses_and_kinds :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	sample(&h)
	find :: proc(h: ^History, q: string, f := History_Filter.All) -> []u64 {
		shown := history_shown(h, q, f, .Date, true, context.temp_allocator)
		return ids_of(h, shown[:])
	}
	testing.expect_value(t, len(find(&h, "")), 5)
	testing.expect(t, slice_is(find(&h, "CLICHE"), {2, 1}))
	testing.expect(t, slice_is(find(&h, "example menu"), {3}))
	testing.expect(t, slice_is(find(&h, "host"), {4}))
	testing.expect(t, slice_is(find(&h, "video"), {2}))
	testing.expect(t, slice_is(find(&h, "world text"), {5}))
	testing.expect_value(t, len(find(&h, "cliche nothing")), 0)
	testing.expect(t, slice_is(find(&h, "", .Screenshots), {4, 1}))
	testing.expect(t, slice_is(find(&h, "", .Recordings), {2}))
	testing.expect(t, slice_is(find(&h, "", .Uploads), {4}))
	testing.expect(t, slice_is(find(&h, "", .Text), {5, 3}))
}

// The filter by date keeps what was made since the start of a local day: today, the last 7 or 30 days.
@(test)
the_date_filter_starts_at_a_local_midnight :: proc(t: ^testing.T) {
	DAY :: i64(86_400_000)
	HOUR :: i64(3_600_000)
	now := 20_000 * DAY + 10 * HOUR   // (10:00 UTC)
	testing.expect_value(t, history_period_start(.Any, now, 0), 0)
	testing.expect_value(t, history_period_start(.Today, now, 0), 20_000 * DAY)
	testing.expect_value(t, history_period_start(.Week, now, 0), 19_994 * DAY)
	testing.expect_value(t, history_period_start(.Month, now, 0), 19_971 * DAY)
	// (at UTC+2 it is 12:00, the day began at 22:00 UTC the day before; at UTC-11, 23:00 of the day before)
	testing.expect_value(t, history_period_start(.Today, now, 120), 20_000 * DAY - 2 * HOUR)
	testing.expect_value(t, history_period_start(.Today, now, -660), 19_999 * DAY + 11 * HOUR)

	h: History
	defer history_destroy(&h)
	history_add(&h, entry(1, now - 2 * DAY, .Region, path = "/p/a.png"), 100)
	history_add(&h, entry(2, now - HOUR, .Picture, path = "/p/b.png"), 100)
	history_add(&h, entry(3, now, .File, path = "/p/c.zip"), 100)
	shown := history_shown(&h, "", .All, .Date, true, context.temp_allocator, since_ms = history_period_start(.Today, now, 0))
	testing.expect(t, slice_is(ids_of(&h, shown[:]), {3, 2}))
	// (a picture that is no capture is a screenshot's kind for the filter; a file is not)
	shown = history_shown(&h, "", .Screenshots, .Date, true, context.temp_allocator)
	testing.expect(t, slice_is(ids_of(&h, shown[:]), {2, 1}))
}

@(test)
the_sort_goes_by_the_column :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	sample(&h)
	by :: proc(h: ^History, c: History_Column, descending: bool) -> []u64 {
		shown := history_shown(h, "", .All, c, descending, context.temp_allocator)
		return ids_of(h, shown[:])
	}
	testing.expect(t, slice_is(by(&h, .Date, false), {1, 2, 3, 4, 5}))
	testing.expect(t, slice_is(by(&h, .Date, true), {5, 4, 3, 2, 1}))
	testing.expect(t, slice_is(by(&h, .Size, true), {2, 1, 4, 5, 3}), "ties: the newest first")
	// (names: cliche-a.png, cliche-b.mp4, the QR code's text, Desk.png, the text's first words; case ignored)
	testing.expect(t, slice_is(by(&h, .Name, false), {1, 2, 4, 5, 3}))
}

@(test)
a_text_names_its_entry_by_its_first_words :: proc(t: ^testing.T) {
	testing.expect_value(t, history_name(entry(1, 0, .Text, text = "Hello\nworld,  the text\tread")), "Hello world, the text read")
	long := strings.repeat("word ", 40, context.temp_allocator)
	name := history_first_words(long, 22)
	testing.expect(t, strings.has_suffix(name, "…"))
	testing.expect(t, len(name) <= 22 + len("…"))
	testing.expect(t, !strings.contains(name, "wor…"), "no word is cut in two")
	testing.expect_value(t, history_name(entry(1, 0, .Region, path = `C:\shots\a.png`)), "a.png")
}

@(test)
a_long_text_is_cut_on_a_character :: proc(t: ^testing.T) {
	text := strings.repeat("é", HISTORY_TEXT_MAX, context.temp_allocator)   // (2 bytes each)
	cut := history_text_cut(text)
	testing.expect(t, len(cut) <= HISTORY_TEXT_MAX)
	testing.expect_value(t, len(cut) % 2, 0)
}

@(test)
the_file_reads_back_what_it_wrote :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	sample(&h)
	odd := entry(9, 9000, .Gif, path = "/p/a\tb\\c.gif", text = "line\nnext\r\\t")
	odd.size, odd.length_ms = {640, 480}, 4200
	history_add(&h, odd, 100)
	text := history_format(h.entries[:], context.temp_allocator)
	testing.expect_value(t, strings.count(text, "\n"), len(h.entries) + 1)
	back := history_parse(text)
	defer {
		for &e in back { history_entry_free(&e) }
		delete(back)
	}
	testing.expect_value(t, len(back), len(h.entries))
	for e, i in back { testing.expect_value(t, e, h.entries[i]) }
}

@(test)
lines_that_do_not_read_are_skipped :: proc(t: ^testing.T) {
	text := HISTORY_HEADER + "\n" +
		"1\t10\tregion\t1\t2\t3\t0\t/a.png\t\t\n" +
		"broken line\n" +
		"2\t20\tunknown\t0\t0\t0\t0\t\t\t\n" +
		"1\t30\tregion\t0\t0\t0\t0\t/again.png\t\t\n" +   // (an id seen already)
		"3\t40\tqr\t0\t0\t0\t0\t\t\thello\r\n"
	back := history_parse(text)
	defer {
		for &e in back { history_entry_free(&e) }
		delete(back)
	}
	testing.expect_value(t, len(back), 2)
	testing.expect_value(t, back[0].path, "/a.png")
	testing.expect_value(t, back[0].size, [2]int{1, 2})
	testing.expect_value(t, back[1].text, "hello")
	other := history_parse("something else\n1\t10\tregion\t0\t0\t0\t0\t\t\t\n")
	defer delete(other)
	testing.expect_value(t, len(other), 0)
}

@(test)
the_file_goes_under_what_was_added_before_it :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	history_add(&h, entry(50, 5000, .Region, path = "/new.png"), 10)
	loaded := make([]History_Entry, 2)
	loaded[0] = history_entry_clone(entry(10, 1000, .Region, path = "/old.png"))
	loaded[1] = history_entry_clone(entry(50, 5000, .Region, path = "/new.png"))   // (the worker had it already)
	history_merge_loaded(&h, loaded, 10)
	delete(loaded)
	testing.expect_value(t, len(h.entries), 2)
	testing.expect_value(t, h.entries[0].id, 10)
	testing.expect_value(t, h.entries[1].id, 50)
	testing.expect_value(t, history_find(&h, 50).path, "/new.png")
	testing.expect(t, history_new_id(&h, 0) > 50)
}

@(test)
missing_files_are_marked :: proc(t: ^testing.T) {
	h: History
	defer history_destroy(&h)
	sample(&h)
	v := h.version
	history_set_missing(&h, {2})
	testing.expect(t, history_find(&h, 2).missing)
	testing.expect(t, h.version != v)
	history_set_missing(&h, {})
	testing.expect(t, !history_find(&h, 2).missing)
}

@(test)
clicks_select_one_more_or_a_range :: proc(t: ^testing.T) {
	s: History_Selection
	defer history_selection_destroy(&s)
	shown := []u64{10, 20, 30, 40, 50}
	history_selection_click(&s, shown, 20, .Alone)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {20}))
	history_selection_click(&s, shown, 40, .Toggle)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {20, 40}))
	history_selection_click(&s, shown, 20, .Toggle)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {40}))
	// (a range from the last click: 20, unmarked, is where it starts)
	history_selection_click(&s, shown, 50, .Range)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {20, 30, 40, 50}))
	history_selection_click(&s, shown, 10, .Range)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {10, 20}))
	testing.expect_value(t, history_selection_place(&s, shown), 0)
}

@(test)
keys_move_and_extend_the_selection :: proc(t: ^testing.T) {
	s: History_Selection
	defer history_selection_destroy(&s)
	shown := []u64{10, 20, 30, 40, 50}
	testing.expect_value(t, history_selection_move(&s, shown, 1, false), 1)
	testing.expect_value(t, history_selection_move(&s, shown, 3, true), 3)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {20, 30, 40}))
	testing.expect_value(t, history_selection_move(&s, shown, 99, false), 4)
	testing.expect(t, slice_is(history_selection_ids(&s, shown), {50}))
	testing.expect_value(t, history_selection_move(&s, {}, 0, false), -1)
	history_selection_all(&s, shown)
	testing.expect_value(t, len(history_selection_ids(&s, shown)), 5)
	// (a filter hides some: they leave the selection)
	history_selection_prune(&s, {10, 30})
	testing.expect(t, slice_is(history_selection_ids(&s, {10, 30}), {10, 30}))
	testing.expect_value(t, s.focus, 0)
}

@(private = "file")
slice_is :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}
