package cliche

// The history: one entry per outcome (a screenshot, a recording, a QR code or a text read), the newest last. The model
// is pure (adding with the cap, the search, the filter, the sort, the selection): the tests drive it without a window.
//
// Two copies of it exist. The interface's thread keeps one for the window (history_view.odin); the worker keeps the
// other, reads the file into it at the start and writes the file after each change. Both apply the same procedures to
// the same jobs, so the interface never formats or writes the file and the worker never waits on the interface. The
// interface gives each entry its id before it sends it: the two copies name an entry the same way.
//
// The file is <state folder>/cliche/history (history_file_*.odin): a first line HISTORY_HEADER, then one line per
// entry, oldest first, its fields separated by tabs and escaped (history_format).

import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/timezone"
import ascii "gt:ascii"
import desktop "gt:desktop"
import "gt:fsx"
import "gt:platform"
import png "gt:png"

HISTORY_HEADER :: "cliche history 1"

// The longest text kept of a QR code or of a text read, in bytes (a whole character): a page of OCR is no history line.
HISTORY_TEXT_MAX :: 4000

// The entries kept when the preference is not read yet.
HISTORY_SIZE_DEFAULT :: 1000

// What an entry is.
History_Kind :: enum u8 { Region, Screen, Window, Video, Gif, Qr, Text }

HISTORY_KIND_NAMES := [History_Kind]string{
	.Region = "region", .Screen = "screen", .Window = "window", .Video = "video", .Gif = "gif", .Qr = "qr", .Text = "text",
}

// The words the window shows for a kind (the Kind column, the search finds them too).
HISTORY_KIND_TEXT := [History_Kind]string{
	.Region = "Region", .Screen = "Screen", .Window = "Window", .Video = "Video", .Gif = "GIF", .Qr = "QR code", .Text = "Text",
}

// The window's filter by kind.
History_Filter :: enum u8 { All, Screenshots, Recordings, Uploads, Text }

HISTORY_FILTER_TEXT := [History_Filter]string{
	.All = "All", .Screenshots = "Screenshots", .Recordings = "Recordings", .Uploads = "Uploads", .Text = "Text",
}

// The columns of the list, and what the entries sort by.
History_Column :: enum u8 { Name, Kind, Size, Date, Url }

History_Entry :: struct {
	id:        u64,
	time_ms:   i64,      // since 1970, UTC
	kind:      History_Kind,
	path:      string,   // the file ("" none: copied or uploaded only, or a text); owned
	url:       string,   // the upload's address ("" none); owned
	text:      string,   // a QR code's or a text's (cut at HISTORY_TEXT_MAX); owned
	size:      [2]int,   // in pixels (0: unknown)
	bytes:     i64,      // the file's (0: unknown)
	length_ms: i64,      // a recording's
	missing:   bool,     // the file is gone (not in the file: the worker looks at each start and when the window shows)
}

History :: struct {
	entries: [dynamic]History_Entry,   // oldest first
	index:   map[u64]int,              // id -> place in `entries`
	last_id: u64,
	version: u64,                      // raised at each change: what is built from the entries is made again
}

history_destroy :: proc(h: ^History) {
	for &e in h.entries { history_entry_free(&e) }
	delete(h.entries)
	delete(h.index)
	h^ = {}
}

history_entry_free :: proc(e: ^History_Entry) {
	delete(e.path)
	delete(e.url)
	delete(e.text)
	e^ = {}
}

// A copy that owns its strings, the text cut.
history_entry_clone :: proc(e: History_Entry, allocator := context.allocator) -> History_Entry {
	out := e
	out.path = strings.clone(e.path, allocator)
	out.url = strings.clone(e.url, allocator)
	out.text = strings.clone(history_text_cut(e.text), allocator)
	return out
}

// `text` up to HISTORY_TEXT_MAX bytes, never inside a character.
history_text_cut :: proc(text: string) -> string {
	if len(text) <= HISTORY_TEXT_MAX { return text }
	end := HISTORY_TEXT_MAX
	for end > 0 && text[end] & 0xC0 == 0x80 { end -= 1 }
	return text[:end]
}

// A new id: above every id given or read, and from the clock, so that ids of two runs do not meet.
history_new_id :: proc(h: ^History, now_ms: i64) -> u64 {
	id := max(h.last_id + 1, u64(max(now_ms, 0)) << 8)
	h.last_id = id
	return id
}

// Adds a copy of `e` (its id given: history_new_id), then drops the oldest beyond `cap`. False: the id is there already.
history_add :: proc(h: ^History, e: History_Entry, cap: int) -> bool {
	if e.id == 0 || e.id in h.index { return false }
	append(&h.entries, history_entry_clone(e))
	h.index[e.id] = len(h.entries) - 1
	h.last_id = max(h.last_id, e.id)
	h.version += 1
	history_trim(h, cap)
	return true
}

// Drops the oldest entries beyond `cap` (at least 1 kept).
history_trim :: proc(h: ^History, cap: int) {
	over := len(h.entries) - max(cap, 1)
	if over <= 0 { return }
	for &e in h.entries[:over] { history_entry_free(&e) }
	remove_range(&h.entries, 0, over)
	history_reindex(h)
}

// Removes the entries of `ids`. Returns how many were there.
history_remove :: proc(h: ^History, ids: []u64) -> int {
	gone := 0
	for id in ids {
		if _, found := h.index[id]; found { gone += 1 }
	}
	if gone == 0 { return 0 }
	drop := make(map[u64]struct{}, len(ids), context.temp_allocator)
	for id in ids { drop[id] = {} }
	kept := 0
	for &e in h.entries {
		if e.id in drop { history_entry_free(&e); continue }
		h.entries[kept] = e
		kept += 1
	}
	resize(&h.entries, kept)
	history_reindex(h)
	return gone
}

// The entry of `id`, nil when there is none (valid until the next change).
history_find :: proc(h: ^History, id: u64) -> ^History_Entry {
	i, found := h.index[id]
	if !found { return nil }
	return &h.entries[i]
}

// The files known gone: `missing` lists them, every other entry has its file (or none).
history_set_missing :: proc(h: ^History, missing: []u64) {
	gone := make(map[u64]struct{}, len(missing), context.temp_allocator)
	for id in missing { gone[id] = {} }
	changed := false
	for &e in h.entries {
		m := e.id in gone
		if m != e.missing { e.missing, changed = m, true }
	}
	if changed { h.version += 1 }
}

// The address an upload gave, kept on its entry.
history_set_url :: proc(h: ^History, id: u64, url: string) {
	e := history_find(h, id)
	if e == nil || e.url == url { return }
	delete(e.url)
	e.url = strings.clone(url)
	h.version += 1
}

// The entries read from the file, put under those added since the start (the interface may add one before the file is
// read). `loaded` is taken: its strings become the history's.
history_merge_loaded :: proc(h: ^History, loaded: []History_Entry, cap: int) {
	added := h.entries
	h.entries = make([dynamic]History_Entry, 0, len(loaded) + len(added))
	clear(&h.index)
	seen := make(map[u64]struct{}, len(loaded), context.temp_allocator)
	for e in loaded {
		append(&h.entries, e)
		seen[e.id] = {}
		h.last_id = max(h.last_id, e.id)
	}
	for &e in added {
		if e.id in seen { history_entry_free(&e); continue }
		append(&h.entries, e)
	}
	delete(added)
	// (an entry added before the file was read is newer than the file's: the order by time holds without a sort, unless
	// the clock went back)
	slice.stable_sort_by(h.entries[:], proc(a, b: History_Entry) -> bool { return a.time_ms < b.time_ms })
	history_reindex(h)
	history_trim(h, cap)
}

@(private = "file")
history_reindex :: proc(h: ^History) {
	clear(&h.index)
	for e, i in h.entries { h.index[e.id] = i }
	h.version += 1
}

////////////////////////////////
// What the window shows

// What the window calls an entry: its file's name, else its text's first words, else its address.
history_name :: proc(e: History_Entry) -> string {
	if e.path != "" { return e.path[strings.last_index_any(e.path, "/\\") + 1:] }
	if e.text != "" { return history_first_words(e.text, HISTORY_NAME_MAX) }
	if e.url != "" { return e.url }
	return HISTORY_KIND_TEXT[e.kind]
}

HISTORY_NAME_MAX :: 60

// The text's start on one line: the spaces and line breaks made one space, cut at a word near `most` bytes, "…" after.
history_first_words :: proc(text: string, most: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, min(len(text), most) + 4, allocator)
	space := false
	cut := false
	for r in text {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			space = strings.builder_len(b) > 0
			continue
		}
		if strings.builder_len(b) >= most { cut = true; break }
		if space { strings.write_byte(&b, ' '); space = false }
		strings.write_rune(&b, r)
	}
	out := strings.to_string(b)
	if !cut { return out }
	// (back to the last space, when there is one in its second half: a word is not cut in two)
	if at := strings.last_index_byte(out, ' '); at > most / 2 { out = out[:at] }
	return strings.concatenate({out, "…"}, allocator)
}

// Whether the entry is of the filter's kind.
history_in_filter :: proc(e: History_Entry, f: History_Filter) -> bool {
	switch f {
	case .All:         return true
	case .Screenshots: return e.kind == .Region || e.kind == .Screen || e.kind == .Window
	case .Recordings:  return e.kind == .Video || e.kind == .Gif
	case .Uploads:     return e.url != ""
	case .Text:        return e.kind == .Qr || e.kind == .Text
	}
	return true
}

// Whether every word of `query` is in the entry's name, text, address or kind (case ignored).
history_matches :: proc(e: History_Entry, query: string) -> bool {
	rest := query
	for word in strings.fields_iterator(&rest) {
		if ascii.contains_fold(history_name(e), word) { continue }
		if ascii.contains_fold(e.text, word) { continue }
		if ascii.contains_fold(e.url, word) { continue }
		if ascii.contains_fold(e.path, word) { continue }
		if ascii.contains_fold(HISTORY_KIND_TEXT[e.kind], word) || ascii.contains_fold(HISTORY_KIND_NAMES[e.kind], word) { continue }
		return false
	}
	return true
}

// The places in `h.entries` of the entries shown: filtered, searched, sorted by `column` (ties: the newest first).
// It passes over every entry: call it when the entries, the query, the filter or the sort change, never per frame.
history_shown :: proc(h: ^History, query: string, filter: History_Filter, column: History_Column, descending: bool, allocator := context.allocator) -> [dynamic]int {
	out := make([dynamic]int, 0, len(h.entries), allocator)
	for e, i in h.entries {
		if history_in_filter(e, filter) && history_matches(e, query) { append(&out, i) }
	}
	Sort :: struct { h: ^History, column: History_Column, descending: bool }
	s := Sort{h, column, descending}
	context.user_ptr = &s
	slice.sort_by(out[:], proc(a, b: int) -> bool {
		s := (^Sort)(context.user_ptr)
		x, y := s.h.entries[a], s.h.entries[b]
		c := history_compare(x, y, s.column)
		if c != 0 { return s.descending ? c > 0 : c < 0 }
		// (ties: the newest first, whatever the direction)
		if x.time_ms != y.time_ms { return x.time_ms > y.time_ms }
		return x.id > y.id
	})
	return out
}

@(private = "file")
history_compare :: proc(x, y: History_Entry, column: History_Column) -> int {
	switch column {
	case .Name: return ascii.compare_fold(history_name(x), history_name(y))
	case .Kind: return ascii.compare_fold(HISTORY_KIND_TEXT[x.kind], HISTORY_KIND_TEXT[y.kind])
	case .Size:
		if x.bytes != y.bytes { return x.bytes < y.bytes ? -1 : 1 }
		ax, ay := x.size.x * x.size.y, y.size.x * y.size.y
		if ax != ay { return ax < ay ? -1 : 1 }
		return 0
	case .Date:
		if x.time_ms != y.time_ms { return x.time_ms < y.time_ms ? -1 : 1 }
		return 0
	case .Url: return ascii.compare_fold(x.url, y.url)
	}
	return 0
}

////////////////////////////////
// The selection of the grid (the list's is its table's, copied in and out: history_view.odin)

History_Selection :: struct {
	marked: map[u64]struct{},   // the entries selected
	focus:  u64,                // the entry the keys move from (0: none); selected unless a Ctrl click took it out
	anchor: u64,                // where a Shift click's or a Shift move's range starts
	version: u64,               // raised at each change: what is made from the selection is made again
}

// How a click selects: alone, Ctrl (one more or one less), Shift (the range from the anchor).
History_Click :: enum u8 { Alone, Toggle, Range }

history_selection_destroy :: proc(s: ^History_Selection) {
	delete(s.marked)
	s^ = {}
}

history_selection_clear :: proc(s: ^History_Selection) {
	clear(&s.marked)
	s.focus, s.anchor = 0, 0
	s.version += 1
}

// Selects `id` alone.
history_select_one :: proc(s: ^History_Selection, id: u64) {
	clear(&s.marked)
	if id != 0 { s.marked[id] = {} }
	s.focus, s.anchor = id, id
	s.version += 1
}

// A click on the entry `id` of `shown` (the ids in the order shown).
history_selection_click :: proc(s: ^History_Selection, shown: []u64, id: u64, how: History_Click) {
	switch how {
	case .Alone:
		history_select_one(s, id)
	case .Toggle:
		if id in s.marked { delete_key(&s.marked, id) } else { s.marked[id] = {} }
		s.focus, s.anchor = id, id
		s.version += 1
	case .Range:
		from, anchored := slice.linear_search(shown, s.anchor != 0 ? s.anchor : id)
		at, found := slice.linear_search(shown, id)
		if !found { return }
		if !anchored { from = at }
		clear(&s.marked)
		for k in min(from, at) ..= max(from, at) { s.marked[shown[k]] = {} }
		s.focus = id
		if s.anchor == 0 { s.anchor = id }
		s.version += 1
	}
}

// A move of the keys: `to` is the place in `shown` the focus goes to (clamped); `extend` (Shift) selects the range from
// the anchor, else the entry alone. Returns the place, -1 when nothing is shown.
history_selection_move :: proc(s: ^History_Selection, shown: []u64, to: int, extend: bool) -> int {
	if len(shown) == 0 { return -1 }
	at := clamp(to, 0, len(shown) - 1)
	history_selection_click(s, shown, shown[at], extend ? .Range : .Alone)
	return at
}

// The place of the focus in `shown` (-1: none, or not shown).
history_selection_place :: proc(s: ^History_Selection, shown: []u64) -> int {
	if s.focus == 0 { return -1 }
	at, found := slice.linear_search(shown, s.focus)
	return found ? at : -1
}

history_selection_all :: proc(s: ^History_Selection, shown: []u64) {
	for id in shown { s.marked[id] = {} }
	if s.focus == 0 && len(shown) > 0 { s.focus, s.anchor = shown[0], shown[0] }
	s.version += 1
}

// Forgets what is no longer shown (a filter, a removal).
history_selection_prune :: proc(s: ^History_Selection, shown: []u64) {
	if len(s.marked) == 0 && s.focus == 0 { return }
	live := make(map[u64]struct{}, len(shown), context.temp_allocator)
	for id in shown { live[id] = {} }
	gone := make([dynamic]u64, context.temp_allocator)
	for id in s.marked { if id not_in live { append(&gone, id) } }
	for id in gone { delete_key(&s.marked, id) }
	if s.focus not_in live { s.focus = 0 }
	if s.anchor not_in live { s.anchor = 0 }
	s.version += 1
}

// The ids selected, in the order shown.
history_selection_ids :: proc(s: ^History_Selection, shown: []u64, allocator := context.temp_allocator) -> []u64 {
	out := make([dynamic]u64, 0, len(s.marked), allocator)
	if len(s.marked) == 0 { return out[:] }
	for id in shown { if id in s.marked { append(&out, id) } }
	return out[:]
}

////////////////////////////////
// The file

// The entries as the file's text: the header, then a line per entry, oldest first.
history_format :: proc(entries: []History_Entry, allocator := context.allocator) -> string {
	b := strings.builder_make(0, 64 + len(entries) * 160, allocator)
	strings.write_string(&b, HISTORY_HEADER)
	strings.write_byte(&b, '\n')
	for e in entries {
		strings.write_u64(&b, e.id)
		strings.write_byte(&b, '\t')
		strings.write_i64(&b, e.time_ms)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, HISTORY_KIND_NAMES[e.kind])
		strings.write_byte(&b, '\t')
		strings.write_int(&b, e.size.x)
		strings.write_byte(&b, '\t')
		strings.write_int(&b, e.size.y)
		strings.write_byte(&b, '\t')
		strings.write_i64(&b, e.bytes)
		strings.write_byte(&b, '\t')
		strings.write_i64(&b, e.length_ms)
		texts := [3]string{e.path, e.url, e.text}
		for field in texts {
			strings.write_byte(&b, '\t')
			history_escape(&b, field)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// The entries of a file's text (each owned). A line that does not read is skipped: a file cut by a crash of another
// writer, or edited by hand, loses that line only.
history_parse :: proc(text: string, allocator := context.allocator) -> [dynamic]History_Entry {
	out := make([dynamic]History_Entry, allocator)
	rest := text
	first := true
	seen := make(map[u64]struct{}, 64, context.temp_allocator)
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_suffix(raw, "\r")
		if first {
			first = false
			if line != HISTORY_HEADER { return out }   // (another program's file, or a later format: nothing is read)
			continue
		}
		e, ok := history_parse_line(line, allocator)
		if !ok || e.id in seen { history_entry_free(&e); continue }
		seen[e.id] = {}
		append(&out, e)
	}
	return out
}

@(private = "file")
history_parse_line :: proc(line: string, allocator := context.allocator) -> (e: History_Entry, ok: bool) {
	fields := strings.split(line, "\t", context.temp_allocator)
	if len(fields) != 10 { return }
	e.id = strconv.parse_u64(fields[0]) or_return
	if e.id == 0 { return }
	e.time_ms = strconv.parse_i64(fields[1]) or_return
	kind_found := false
	for name, k in HISTORY_KIND_NAMES { if name == fields[2] { e.kind, kind_found = k, true } }
	if !kind_found { return }
	e.size.x = strconv.parse_int(fields[3]) or_return
	e.size.y = strconv.parse_int(fields[4]) or_return
	e.bytes = strconv.parse_i64(fields[5]) or_return
	e.length_ms = strconv.parse_i64(fields[6]) or_return
	e.path = history_unescape(fields[7], allocator)
	e.url = history_unescape(fields[8], allocator)
	e.text = history_unescape(fields[9], allocator)
	return e, true
}

// A field on one line: \ \t \n \r written as \\ \t \n \r.
@(private = "file")
history_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\': strings.write_string(b, `\\`)
		case '\t': strings.write_string(b, `\t`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case:      strings.write_byte(b, s[i])
		}
	}
}

@(private = "file")
history_unescape :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '\\') < 0 { return strings.clone(s, allocator) }
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 == len(s) { strings.write_byte(&b, s[i]); continue }
		i += 1
		switch s[i] {
		case 't': strings.write_byte(&b, '\t')
		case 'n': strings.write_byte(&b, '\n')
		case 'r': strings.write_byte(&b, '\r')
		case:     strings.write_byte(&b, s[i])   // (\\, and any other: the byte itself)
		}
	}
	return strings.to_string(b)
}

////////////////////////////////
// The worker's side

// The jobs of the history, for the worker (worker.odin's Job has Job_History). Each owns what it holds.
History_Load   :: struct { cap: int }                       // the file read: History_Loaded comes back
History_Add    :: struct { entry: History_Entry, cap: int }   // an entry kept (its id given), the file written
History_Remove :: struct { ids: []u64 }                       // entries forgotten (their files stay)
History_Trim   :: struct { cap: int }                       // history.size changed
History_Check  :: struct {}                                   // which files are gone: History_Checked comes back
History_Delete :: struct { ids: []u64 }                       // their files deleted (the entries stay, missing)
History_Thumb_Ask :: struct { id: u64, path: string, size: int, picture: bool }   // a thumbnail: History_Thumb comes back
History_Picture_Ask :: struct { id: u64, path: string, purpose: History_Picture_Purpose }   // the PNG decoded
History_Upload :: struct { id: u64, path, uploader: string }  // the file uploaded again: History_Uploaded comes back
History_Open   :: struct { path: string }                     // the file opened with the system's program

Job_History :: union { History_Load, History_Add, History_Remove, History_Trim, History_Check, History_Delete, History_Thumb_Ask, History_Picture_Ask, History_Upload, History_Open }

// What a picture is decoded for.
History_Picture_Purpose :: enum u8 { Preview, Copy }

// The file's entries (owned: history_merge_loaded takes them), the files gone, and the local time's offset from UTC (read
// here: it reads the time zone's file).
History_Loaded :: struct { entries: []History_Entry, missing: []u64, offset_minutes: int }
History_Checked :: struct { missing: []u64 }   // (owned)
// A thumbnail (owned; ok false: none, an icon stands for it), at most `asked` pixels on its longer side.
History_Thumb :: struct { id: u64, asked: int, rgba: []u8, size: [2]int, ok: bool }
History_Pixels :: struct { id: u64, purpose: History_Picture_Purpose, rgba: []u8, size: [2]int, ok: bool, png: []u8 }   // (owned; png: the file, for Copy: the clipboard takes it as it is)
History_Uploaded :: struct { id: u64, url, problem: string }   // (owned)

Result_History :: union { History_Loaded, History_Checked, History_Thumb, History_Pixels, History_Uploaded }

// The worker's copy of the history and where its file is.
History_Disk :: struct {
	history: History,
	path:    string,   // (owned) "": no file here, the history lives in memory only
	loaded:  bool,
	cap:     int,
}

history_disk_free :: proc(d: ^History_Disk) {
	history_destroy(&d.history)
	delete(d.path)
	d^ = {}
}

// Runs a job of the history, on the worker, and frees it. `has`: a result to post.
history_job_run :: proc(d: ^History_Disk, j: Job_History) -> (r: Result_History, has: bool) {
	j := j
	defer history_job_free(&j)
	switch v in j {
	case History_Load:
		d.cap = v.cap
		if d.path == "" { d.path = history_file() }
		if !d.loaded && d.path != "" {
			if data, ok := fsx.read_all(d.path, context.temp_allocator); ok {
				entries := history_parse(string(data))
				history_merge_loaded(&d.history, entries[:], d.cap)
				delete(entries)
			}
		}
		d.loaded = true
		loaded := History_Loaded{entries = make([]History_Entry, len(d.history.entries)), offset_minutes = history_offset_minutes()}
		for e, i in d.history.entries { loaded.entries[i] = history_entry_clone(e) }
		loaded.missing = history_missing(&d.history)
		return loaded, true
	case History_Add:
		if history_add(&d.history, v.entry, v.cap) { history_disk_write(d) }
	case History_Remove:
		if history_remove(&d.history, v.ids) > 0 { history_disk_write(d) }
	case History_Trim:
		d.cap = v.cap
		before := len(d.history.entries)
		history_trim(&d.history, v.cap)
		if len(d.history.entries) != before { history_disk_write(d) }
	case History_Check:
		return History_Checked{history_missing(&d.history)}, true
	case History_Delete:
		for id in v.ids {
			if e := history_find(&d.history, id); e != nil && e.path != "" { _ = os.remove(e.path) }
		}
		return History_Checked{history_missing(&d.history)}, true
	case History_Thumb_Ask:
		return history_thumbnail(v), true
	case History_Picture_Ask:
		out := History_Pixels{id = v.id, purpose = v.purpose}
		if data, ok := fsx.read_all(v.path, context.temp_allocator); ok {
			out.rgba, out.size.x, out.size.y, out.ok = png.decode(data)
			// (the file is the clipboard's PNG already: the interface's thread encodes nothing)
			if out.ok && v.purpose == .Copy { out.png = slice.clone(data) }
		}
		return out, true
	case History_Upload:
		out := History_Uploaded{id = v.id}
		data, ok := fsx.read_all(v.path, context.temp_allocator)
		if !ok {
			out.problem = strings.clone("the file cannot be read")
			return out, true
		}
		list, _ := uploaders_load(context.temp_allocator)
		u, _ := uploader_find(list, v.uploader)
		if u == nil {
			out.problem = strings.clone("no uploader is set up")
			return out, true
		}
		out.url, out.problem = upload_shot(u^, data, v.path[strings.last_index_any(v.path, "/\\") + 1:])
		if out.url != "" {
			history_set_url(&d.history, v.id, out.url)
			history_disk_write(d)
		}
		return out, true
	case History_Open:
		_ = platform.open_path(v.path)
	}
	return
}

history_job_free :: proc(j: ^Job_History) {
	switch &v in j {
	case History_Load, History_Trim, History_Check:
	case History_Add:    history_entry_free(&v.entry)
	case History_Remove: delete(v.ids)
	case History_Delete: delete(v.ids)
	case History_Thumb_Ask: delete(v.path)
	case History_Picture_Ask: delete(v.path)
	case History_Upload: delete(v.path); delete(v.uploader)
	case History_Open:   delete(v.path)
	}
	j^ = nil
}

history_result_free :: proc(r: ^Result_History) {
	switch &v in r {
	case History_Loaded:
		for &e in v.entries { history_entry_free(&e) }
		delete(v.entries)
		delete(v.missing)
	case History_Checked:  delete(v.missing)
	case History_Thumb:    delete(v.rgba)
	case History_Pixels:   delete(v.rgba); delete(v.png)
	case History_Uploaded: delete(v.url); delete(v.problem)
	}
	r^ = nil
}

// The file written whole from the worker's copy (a failure is said, the next change writes it again).
@(private = "file")
history_disk_write :: proc(d: ^History_Disk) {
	if d.path == "" || !d.loaded { return }
	text := history_format(d.history.entries[:], context.temp_allocator)
	if !write_file(d.path, transmute([]u8)text) { log.errorf("the history cannot be written to %s", d.path) }
}

// The ids whose file is gone (a stat each: the worker's).
@(private = "file")
history_missing :: proc(h: ^History) -> []u64 {
	out := make([dynamic]u64)
	for e in h.entries {
		if e.path != "" && !os.exists(e.path) { append(&out, e.id) }
	}
	return out[:]
}

// The thumbnail: the system's (its cache, else its thumbnailer); a PNG of cliche's with none is decoded and reduced here,
// then kept in the system's cache, where the next start and other programs find it.
@(private = "file")
history_thumbnail :: proc(v: History_Thumb_Ask) -> History_Thumb {
	out := History_Thumb{id = v.id, asked = v.size}
	if th, ok := desktop.thumbnail(v.path, v.size); ok {
		out.rgba, out.size, out.ok = th.rgba, th.size, true
		return out
	}
	if !v.picture { return out }
	data, read := fsx.read_all(v.path, context.temp_allocator)
	if !read { return out }
	rgba, w, h, decoded := png.decode(data, context.temp_allocator)
	if !decoded || w <= 0 || h <= 0 { return out }
	k := f32(v.size) / f32(max(w, h))
	dw, dh := w, h
	if k < 1 { dw, dh = max(1, int(f32(w) * k + 0.5)), max(1, int(f32(h) * k + 0.5)) }
	out.rgba = platform.rgba_resample(rgba, w, h, dw, dh)
	out.size, out.ok = {dw, dh}, true
	_ = desktop.thumbnail_store(v.path, out.rgba, dw, dh)
	return out
}

// The local time's offset from UTC now, in minutes (it reads the time zone's file).
@(private = "file")
history_offset_minutes :: proc() -> int {
	now := time.now()
	dt, ok := time.time_to_datetime(now)
	if !ok { return 0 }
	region, loaded := timezone.region_load("local", context.temp_allocator)
	if !loaded { return 0 }
	local, converted := timezone.datetime_to_tz(dt, region)
	if !converted { return 0 }
	lt, lok := time.datetime_to_time(local)
	if !lok { return 0 }
	return int(time.diff(now, lt) / time.Minute)
}

// The history's file: what cliche keeps of its own past belongs to the state folder, not to the preferences. It reads
// the environment: the worker calls it.
history_file :: proc(allocator := context.allocator) -> string {
	dir := platform.user_dir(.State, APP_NAME, context.temp_allocator)
	if dir == "" { return "" }
	return strings.concatenate({dir, "/history"}, allocator)
}
