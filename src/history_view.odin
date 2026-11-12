package cliche

// cliche's main window, the history: the captures kept (history.odin), in a grid of thumbnails or in a list, with a
// search, a filter by kind, a preview of the picture selected (Space) and the usual actions: open, show in its folder,
// copy, edit, upload again, delete the file, forget the entry. The settings show in it, in place of the history
// (settings_view.odin): the gear of the toolbar and Ctrl+, open them, the back bar and Escape go back. Made at its first
// show, hidden at a close, in the theme of appearance.theme, with the command palette (Ctrl+K) and the sheet of keys
// (F1) of both modes.
//
// What is slow goes to the worker (history.odin's jobs): the file, the thumbnails, a picture decoded, an upload, a file
// opened or deleted. A thumbnail is a texture only while its entry is in view: the grid is a virtual list of lines of
// cells, and the textures of the entries not built in the last frames are freed after each frame.
//
// The selection of the grid is the model's (History_Selection); the list's is its table's (ui.Table, with marks). One
// is copied into the other when the view changes, so the actions read one selection.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import config "gt:config"
import "gt:draw"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import timefmt "gt:timefmt"
import "gt:ui"

HISTORY_WINDOW_SIZE :: [2]int{1000, 680}

// The thumbnails asked of the system: its "large" cache (256 pixels), enough for the largest cell.
HISTORY_THUMB_ASK :: 256
// Thumbnails asked of the worker at once: a fast scroll does not queue the whole history behind the next job.
HISTORY_THUMBS_IN_FLIGHT :: 6
// Frames a texture stays after its entry left the view (a scroll back finds it).
HISTORY_THUMB_KEEP_FRAMES :: 30
// The side of a thumbnail's cell per step of history.thumbnail_size, in ems.
HISTORY_CELL_EM := [3]f32{7, 10, 14}
// The preview's pane, in ems.
HISTORY_PREVIEW_EM     :: 26   // the preview pane's width at first, in ems (history.preview_width)
HISTORY_PREVIEW_MIN_EM :: 14
HISTORY_PREVIEW_MAX_EM :: 80
// Entries an action opens at once (each starts a program).
HISTORY_OPEN_MAX :: 8

History_View_Mode :: enum u8 { Grid, List }

HISTORY_VIEW_NAMES := [History_View_Mode]string{.Grid = "grid", .List = "list"}
HISTORY_THUMBNAIL_NAMES := [3]string{"small", "medium", "large"}

// The list's columns, in the order of History_Column.
HISTORY_COLUMNS := [History_Column]ui.Table_Column{
	.Name = {title = "Name", width = 0},
	.Kind = {title = "Kind", width = 7},
	.Size = {title = "Size", width = 13, number = true},
	.Date = {title = "Date", width = 10, number = true},
	.Url  = {title = "URL", width = 18, weak = true},
}

History_Thumb_State :: enum u8 { Asked, Ready, None }

History_Texture :: struct {
	state: History_Thumb_State,
	tex:   render.Texture,
	size:  [2]int,
	seen:  u64,   // the last frame its entry was built
}

History_Window :: struct {
	host:        host.Host,
	opened:      bool,
	visible:     bool,
	hide_due:    bool,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	palette:     ui.Command_Palette,
	sheet_open:  bool,

	history:     History,         // the interface's copy (history.odin)
	loaded:      bool,            // the file was read
	offset_minutes: int,          // the local time's, read by the worker

	search:      ui.Text_Field,
	search_key:  ui.Key,
	search_focused: bool,
	query:       string,          // the search the entries shown were made with (owned)
	filter:      History_Filter,
	sort:        History_Column,
	descending:  bool,
	shown:       [dynamic]int,    // places in history.entries, in the order shown
	shown_ids:   [dynamic]u64,
	shown_version: u64,           // history.version the lists were made at
	shown_due:   bool,            // the search, the filter or the sort changed
	selection:   History_Selection,

	table:       ui.Table,
	table_data:  ui.Table_Data,
	table_due:   bool,            // the table's rows are made again at its next build
	table_give:  bool,            // the grid's selection goes to the table at its next build
	mode_built:  History_View_Mode,

	grid:        ui.Virtual_List,
	grid_rows:   [dynamic]u64,    // a line of cells each
	grid_columns: int,
	grid_version: u64,
	grid_reveal: bool,            // the focus is brought into view at the next build

	thumbs:      map[u64]History_Texture,
	thumbs_asked: int,
	frame:       u64,
	today:       int,             // the local day of this frame (timefmt.local_day)

	preview_open: bool,
	preview:     ui.Preview,
	preview_id:  u64,             // the entry of preview_tex (0: none)
	preview_asked: u64,
	preview_tex: render.Texture,
	preview_size: [2]int,

	enabled:     History_Actions,   // history_enabled's, as of `enabled_stamp`
	enabled_stamp: [3]u64,
	enabled_made: bool,

	menu_key:    ui.Key,
	settings_mode: Settings_Mode,   // settings_view.odin
	workflow_mode: Workflow_Mode,   // workflow_view.odin
	confirm_open: bool,
	delete_ids:  [dynamic]u64,
	status:      string,          // what the last action did, under the view (owned)
}

// The actions of the palette, the menu, the sheet of keys.
History_Action :: enum u8 {
	Open, Reveal, Copy_Picture, Copy_Path, Copy_Url, Copy_Text, Edit, Upload, Delete_File, Remove,
	Preview, Select_All, Search, Grid, List, Open_Folder, Capture_Region, Workflows, Settings, Palette, Keys, Close, Quit,
}

HISTORY_ACTIONS := [History_Action]ui.Command{
	.Open           = {label = "Open", group = "Capture", keys = {{.Return, {}}, {}}, icon = lucide.EXTERNAL_LINK, tags = {"view", "launch"}},
	.Reveal         = {label = "Open the folder", group = "Capture", keys = {{.Return, {.Ctrl}}, {}}, icon = lucide.FOLDER_OPEN, tags = {"reveal", "show", "file manager", "explorer"}},
	.Copy_Picture   = {label = "Copy the picture", group = "Capture", keys = {{.C, {.Ctrl}}, {}}, icon = lucide.COPY, tags = {"clipboard", "image"}},
	.Copy_Path      = {label = "Copy the path", group = "Capture", keys = {{.C, {.Ctrl, .Shift}}, {}}, icon = lucide.CLIPBOARD_COPY, tags = {"clipboard", "file", "location"}},
	.Copy_Url       = {label = "Copy the URL", group = "Capture", keys = {{.L, {.Ctrl}}, {}}, icon = lucide.LINK, tags = {"clipboard", "address", "link", "upload"}},
	.Copy_Text      = {label = "Copy the text", group = "Capture", keys = {{.T, {.Ctrl}}, {}}, icon = lucide.FILE_TEXT, tags = {"clipboard", "ocr", "qr"}},
	.Edit           = {label = "Edit", group = "Capture", keys = {{.E, {.Ctrl}}, {}}, icon = lucide.PENCIL, tags = {"editor", "annotate", "draw"}},
	.Upload         = {label = "Upload again", group = "Capture", keys = {{.U, {.Ctrl}}, {}}, icon = lucide.SEND_HORIZONTAL, tags = {"share", "host", "link"}},
	.Delete_File    = {label = "Delete the file…", group = "Capture", keys = {{.Delete, {.Shift}}, {}}, icon = lucide.TRASH_2, tags = {"erase", "remove", "disk"}},
	.Remove         = {label = "Remove from the history", group = "Capture", keys = {{.Delete, {}}, {}}, icon = lucide.X, tags = {"forget", "clear"}},
	.Preview        = {label = "Preview", group = "View", keys = {{.Space, {}}, {}}, icon = lucide.EYE, tags = {"zoom", "look"}},
	.Select_All     = {label = "Select all", group = "View", keys = {{.A, {.Ctrl}}, {}}, icon = lucide.LIST_CHECKS, tags = {"every"}},
	.Search         = {label = "Search", group = "View", keys = {{.F, {.Ctrl}}, {}}, icon = lucide.SEARCH, tags = {"find", "filter"}},
	.Grid           = {label = "Show a grid", group = "View", keys = {{.N1, {.Ctrl}}, {}}, icon = lucide.LAYOUT_GRID, tags = {"thumbnails", "pictures"}},
	.List           = {label = "Show a list", group = "View", keys = {{.N2, {.Ctrl}}, {}}, icon = lucide.LAYOUT_LIST, tags = {"table", "details", "columns"}},
	.Open_Folder    = {label = "Open the save folder", group = "View", icon = lucide.FOLDER_OPEN, tags = {"files", "explorer", "screenshots"}},
	.Capture_Region = {label = "Capture a region", group = "Window", icon = lucide.IMAGE, tags = {"screenshot", "new"}},
	.Workflows      = {label = "Workflows", group = "Window", keys = {{.W, {.Ctrl, .Shift}}, {}}, icon = lucide.GIT_FORK, tags = {"after capture", "steps", "pipeline", "actions", "graph"}},
	.Settings       = {label = "Settings", group = "Window", keys = {{.Comma, {.Ctrl}}, {}}, icon = lucide.SETTINGS, tags = {"preferences", "options"}},
	.Palette        = {label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND, tags = {"actions", "search"}},
	.Keys           = {label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}, {}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}},
	.Close          = {label = "Close the window", group = "Window", keys = {{.W, {.Ctrl}}, {}}, icon = lucide.X, tags = {"hide"}},
	.Quit           = {label = "Quit cliche", group = "Window", keys = {{.Q, {.Ctrl}}, {}}, icon = lucide.POWER, tags = {"exit", "stop"}},
}

History_Actions :: bit_set[History_Action]

// The actions whose keys a text field keeps while it has the keyboard (Enter, Space, Ctrl+C, Delete, Ctrl+A...).
HISTORY_FIELD_KEYS :: History_Actions{.Open, .Copy_Picture, .Copy_Path, .Delete_File, .Remove, .Preview, .Select_All}

// The context menu, in its order; a separator before each of HISTORY_MENU_BREAKS.
@(rodata)
HISTORY_MENU := [?]History_Action{.Open, .Reveal, .Edit, .Copy_Picture, .Copy_Path, .Copy_Url, .Copy_Text, .Upload, .Delete_File, .Remove}
HISTORY_MENU_BREAKS :: History_Actions{.Copy_Picture, .Upload, .Delete_File}

////////////////////////////////
// What the app calls

// Reads the file, on the worker: at the start, after worker_start.
history_start :: proc(app: ^App) {
	worker_send(&app.worker, Job_History(History_Load{cap = app.settings.history_size}))
}

// The kind of a screenshot of `source`.
history_kind_of :: proc(source: Source) -> History_Kind {
	switch source {
	case .Region: return .Region
	case .Screen: return .Screen
	case .Window: return .Window
	}
	return .Region
}

// An outcome kept: in the window's copy now, in the file on the worker. `e`'s strings are not kept: copies are.
// Returns the entry's id (a notification's click shows it).
history_note :: proc(app: ^App, e: History_Entry) -> u64 {
	hw := &app.history_window
	e := e
	now := time.now()
	if e.time_ms == 0 { e.time_ms = i64(time.to_unix_nanoseconds(now) / 1_000_000) }
	e.id = history_new_id(&hw.history, e.time_ms)
	if !history_add(&hw.history, e, app.settings.history_size) { return 0 }
	worker_send(&app.worker, Job_History(History_Add{entry = history_entry_clone(e), cap = app.settings.history_size}))
	return e.id
}

// The preferences changed: fewer entries kept, another view, another size of thumbnails.
history_prefs_changed :: proc(app: ^App) {
	hw := &app.history_window
	before := len(hw.history.entries)
	history_trim(&hw.history, app.settings.history_size)
	if len(hw.history.entries) != before || hw.loaded {
		worker_send(&app.worker, Job_History(History_Trim{cap = app.settings.history_size}))
	}
}

// The preferences of the history, as prefs_read copies them into Settings.
history_settings_read :: proc(p: ^config.Prefs) -> (size: int, view: History_View_Mode, thumbnail: int, preview_em: f32) {
	preview_em = f32(config.float_of(p, "history.preview_width"))
	size = int(config.int_of(p, "history.size"))
	if size <= 0 { size = HISTORY_SIZE_DEFAULT }
	view = config.string_of(p, "history.view") == HISTORY_VIEW_NAMES[.List] ? .List : .Grid
	thumbnail = 1
	t := config.string_of(p, "history.thumbnail_size")
	for name, i in HISTORY_THUMBNAIL_NAMES { if name == t { thumbnail = i } }
	return
}

// Shows the window, on the history (settings_show then goes to the settings); `select`: the entry to select and bring
// into view (0: the selection stays).
history_window_show :: proc(app: ^App, select: u64 = 0) {
	hw := &app.history_window
	if !hw.opened && !history_window_open(app, headless = false) { return }
	settings_leave(app)
	workflow_mode_leave(app)
	token := app_take_token(app)
	defer delete(token)
	if !hw.visible {
		host.host_show(&hw.host)
		hw.visible = true
		hw.shown_due = true
		ui.field_select_all(&hw.search)
		// (a file deleted elsewhere since: its entry shows as missing)
		worker_send(&app.worker, Job_History(History_Check{}))
	}
	if select != 0 {
		history_select_one(&hw.selection, select)
		hw.table_give = true
		hw.grid_reveal = true
	}
	platform.raise_window_token(hw.host.win, token)
	hw.host.settle = max(hw.host.settle, 3)
}

// Opens the window (hidden). `headless`: offscreen, on the software renderer (shots.odin).
history_window_open :: proc(app: ^App, headless: bool) -> bool {
	hw := &app.history_window
	if !host.host_open(&hw.host, &app.shared, {title = "cliche", size = HISTORY_WINDOW_SIZE, headless = headless}, history_build, app) {
		fmt.eprintln("cliche: the main window cannot open")
		return false
	}
	hw.opened = true
	hw.host.input = history_input
	hw.host.params = history_params
	hw.host.after_input = 3
	hw.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	hw.host.state.icon_font = hw.icons
	hw.menu_key = ui.key_from_string(0, "history_menu")
	hw.sort, hw.descending = .Date, true
	ui.table_init(&hw.table, slice.enumerated_array(&HISTORY_COLUMNS), int(History_Column.Date), descending = true)
	hw.table.vl.multi = true
	hw.table.lead = history_table_lead
	hw.table.lead_user = app
	hw.table.lead_em = 2.2
	hw.grid.sel = -1
	hw.grid.no_typeahead = true
	hw.table.vl.no_typeahead = true
	app_wake_set(app, .History, hw.host.win)
	return true
}

// The worker's results of the history.
history_result :: proc(app: ^App, r: Result_History) {
	r := r
	defer history_result_free(&r)
	hw := &app.history_window
	switch &v in r {
	case History_Loaded:
		history_merge_loaded(&hw.history, v.entries, app.settings.history_size)
		delete(v.entries)
		v.entries = nil   // (the strings are the history's now)
		history_set_missing(&hw.history, v.missing)
		hw.offset_minutes = v.offset_minutes
		hw.loaded = true
	case History_Checked:
		history_set_missing(&hw.history, v.missing)
	case History_Thumb:
		hw.thumbs_asked = max(hw.thumbs_asked - 1, 0)
		t, found := &hw.thumbs[v.id]
		if !found { return }
		if !hw.visible {
			delete_key(&hw.thumbs, v.id)   // (hidden meanwhile: asked again when shown)
			return
		}
		if !v.ok || v.size.x <= 0 || v.size.y <= 0 {
			t.state = .None   // (an icon stands for it; not asked again while the window lives)
			return
		}
		t.tex = render.create_texture_rgba(&app.shared.r, v.size.x, v.size.y)
		render.update_texture_rgba(&app.shared.r, t.tex, 0, 0, v.size.x, v.size.y, v.rgba)
		t.size, t.state = v.size, .Ready
	case History_Pixels:
		history_pixels(app, v)
	case History_Uploaded:
		if v.url != "" {
			history_set_url(&hw.history, v.id, v.url)
			platform.clipboard_set(app.anchor, {text = v.url})
			history_status(hw, fmt.tprintf("Uploaded, the URL is on the clipboard: %s", v.url))
		} else {
			history_status(hw, fmt.tprintf("Not uploaded: %s", v.problem))
		}
	}
}

@(private = "file")
history_pixels :: proc(app: ^App, v: History_Pixels) {
	hw := &app.history_window
	switch v.purpose {
	case .Copy:
		if !v.ok { history_status(hw, "The picture cannot be read"); return }
		if platform.clipboard_set_image(app.anchor, {rgba = v.rgba, size = v.size, png = v.png}) {
			history_status(hw, "The picture is on the clipboard")
		} else {
			history_status(hw, "The picture cannot go to the clipboard")
		}
	case .Preview:
		if v.id != hw.preview_asked || !hw.visible { return }
		history_preview_drop(app)
		if !v.ok { return }
		hw.preview_tex = render.create_texture_rgba(&app.shared.r, v.size.x, v.size.y)
		render.update_texture_rgba(&app.shared.r, hw.preview_tex, 0, 0, v.size.x, v.size.y, v.rgba)
		hw.preview_id, hw.preview_size = v.id, v.size
		ui.preview_reset(&hw.preview)
	}
}

history_after_frame :: proc(app: ^App) {
	hw := &app.history_window
	// (the textures of the entries that left the view; a map as large as the view, not as the history)
	gone := make([dynamic]u64, context.temp_allocator)
	for id, t in hw.thumbs {
		if t.state == .Ready && t.seen + HISTORY_THUMB_KEEP_FRAMES < hw.frame { append(&gone, id) }
	}
	for id in gone { history_thumb_drop(app, id) }
	if !hw.hide_due { return }
	hw.hide_due = false
	hw.palette.open = false
	hw.sheet_open = false
	hw.confirm_open = false
	hw.workflow_mode.add.open = false
	hw.workflow_mode.confirm_open = false
	ui.ctx_menu_close()
	host.host_hide(&hw.host)
	hw.visible = false
	history_textures_drop(app)
	workflow_textures_drop(app)
	workflows_save(app)
}

// Before the windows close (the textures are the renderer's): app_windows_close calls it first. The host stays for
// host_close.
history_window_free :: proc(app: ^App) {
	hw := &app.history_window
	history_textures_drop(app)
	delete(hw.thumbs)
	ui.palette_destroy(&hw.palette)
	settings_mode_free(app)
	workflow_mode_free(app)
	ui.field_destroy(&hw.search)
	ui.table_destroy(&hw.table)
	ui.table_data_destroy(&hw.table_data)
	ui.vlist_destroy(&hw.grid)
	history_selection_destroy(&hw.selection)
	history_destroy(&hw.history)
	delete(hw.query)
	delete(hw.shown)
	delete(hw.shown_ids)
	delete(hw.grid_rows)
	delete(hw.delete_ids)
	delete(hw.status)
	hw.status, hw.query = "", ""
}

////////////////////////////////
// The window

@(private = "file")
history_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	hw := &app.history_window
	a := app.settings.appearance
	choice := prefs_page.appearance_choice(a)
	choice.glow = 1
	if ui.theme_show(&app.shared.theme, themes(), choice, &hw.theme_shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !hw.theme_shown.light)
	}
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
}

@(private = "file")
history_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		if e.kind == .Close {
			platform.cancel_close(h.win)
			app.history_window.hide_due = true
			continue
		}
		append(&out, e)
	}
	return out[:]
}

@(private = "file")
history_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	hw := &app.history_window
	hw.frame += 1
	now_ms := f64(time.to_unix_nanoseconds(time.now())) / 1e6
	hw.today = timefmt.local_day(now_ms, hw.offset_minutes)
	em := ui.font_size()
	history_refresh(app)
	if hw.mode_built != app.settings.history_view {
		// (the selection goes to the view shown now)
		if app.settings.history_view == .List { hw.table_give = true } else { hw.grid_reveal = true }
		hw.mode_built = app.settings.history_view
	}

	workflows := hw.workflow_mode.open
	dialog := hw.palette.open || hw.sheet_open || hw.confirm_open || ui.ctx_menu_any_open() || hw.workflow_mode.add.open || hw.workflow_mode.confirm_open
	settings := hw.settings_mode.open
	if !dialog && workflows {
		workflow_keys(app)
		// (the window's own commands; the history's other keys mean nothing here)
		if !hw.workflow_mode.typing { history_keys(app) }
	} else if !dialog && settings {
		settings_keys(app)
		// (the window's own commands; the history's other keys mean nothing on the settings)
		if !prefs_page.editing(&hw.settings_mode.page) { history_keys(app) }
	} else if !dialog {
		if ui.key_press(.Escape) {
			if hw.search_focused && len(hw.search.buf) > 0 { ui.field_set(&hw.search, ""); hw.shown_due = true } else { hw.hide_due = true }
		}
		history_keys(app)
		ui.type_to_field(hw.search_key)
	}

	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###history") {   // (the theme's surface: the host only clears to black)
		switch {
		case workflows: workflow_build(app, em)
		case settings:  settings_build(app, em)
		case:           history_page(app, em)
		}
	}
	if !settings && !workflows { history_menu(app, em) }
	history_dialogs(app)
}

// The history's mode: the toolbar, the grid or the list (and the preview), the footer.
@(private = "file")
history_page :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	history_toolbar(app, em)
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###body") {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###main") {
			history_main(app, em)
		}
		if hw.preview_open {
			// (the rule between the view and the pane, dragged, sets the pane's width: kept when let go)
			w := app.settings.history_preview_em
			ui.next({height = ui.fill()})
			split := ui.splitter("###preview_split", .X, &w, HISTORY_PREVIEW_MIN_EM, HISTORY_PREVIEW_MAX_EM,
				{after = true, unit = em, flush = true, line_at = .Start, default_size = HISTORY_PREVIEW_EM})
			if split.changed { app.settings.history_preview_em = w }
			if split.finished { history_pref(app, "history.preview_width", fmt.tprintf("%.1f", w)) }
			history_preview_pane(app, em)
		}
	}
	history_footer(app, em)
}

// The entries shown, made again when the history, the search, the filter or the sort changed (not per frame).
@(private = "file")
history_refresh :: proc(app: ^App) {
	hw := &app.history_window
	query := strings.trim_space(ui.field_string(&hw.search))
	if query != hw.query { hw.shown_due = true }
	if !hw.shown_due && hw.shown_version == hw.history.version { return }
	delete(hw.query)
	hw.query = strings.clone(query)
	delete(hw.shown)
	hw.shown = history_shown(&hw.history, hw.query, hw.filter, hw.sort, hw.descending)
	resize(&hw.shown_ids, len(hw.shown))
	for p, i in hw.shown { hw.shown_ids[i] = hw.history.entries[p].id }
	hw.shown_version = hw.history.version
	hw.shown_due = false
	hw.table_due = true
	hw.grid_columns = 0   // (the grid's lines are made again)
	history_selection_prune(&hw.selection, hw.shown_ids[:])
}

@(private = "file")
history_toolbar :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.9)), axis = .X, cross = .Center})
	if ui.row(id = "###toolbar") {
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		r := ui.line_edit("###search", &hw.search, "Search names, texts, URLs", clearable = true)
		if r.box != nil { hw.search_key = r.box.key }
		hw.search_focused = r.focused
		if r.changed { hw.shown_due = true }
		if r.committed { hw.grid_reveal = true }
		ui.spacer(ui.px(em * 0.8))
		chosen := int(hw.filter)
		ui.next({width = ui.px(math.round(em * 31)), height = ui.px(math.round(em * 1.9))})
		if ui.segmented("filter", slice.enumerated_array(&HISTORY_FILTER_TEXT), &chosen) {
			hw.filter = History_Filter(chosen)
			hw.shown_due = true
		}
		ui.spacer(ui.px(em * 0.8))
		if app.settings.history_view == .Grid {
			sizes := [3]string{"S", "M", "L"}
			tips := [3]string{"Small thumbnails", "Medium thumbnails", "Large thumbnails"}
			step := app.settings.history_thumbnail
			ui.next({width = ui.px(math.round(em * 6.5)), height = ui.px(math.round(em * 1.9))})
			if ui.segmented("thumb_size", sizes[:], &step, tips[:]) { history_pref(app, "history.thumbnail_size", HISTORY_THUMBNAIL_NAMES[clamp(step, 0, 2)]) }
			ui.spacer(ui.px(em * 0.6))
		}
		views := [2]string{"Grid", "List"}
		view := int(app.settings.history_view)
		ui.next({width = ui.px(math.round(em * 8)), height = ui.px(math.round(em * 1.9))})
		if ui.segmented("view", views[:], &view) {
			if view == 0 { history_action(app, .Grid) } else { history_action(app, .List) }
		}
		ui.spacer(ui.px(em * 0.6))
		if history_icon_button("preview", lucide.EYE, hw.preview_open ? "Hide the preview (Space)" : "Preview (Space)", em) { history_action(app, .Preview) }
		if history_icon_button("folder", lucide.FOLDER_OPEN, "Open the save folder", em) { history_action(app, .Open_Folder) }
		if history_icon_button("workflows", lucide.GIT_FORK, "Workflows: what happens after a capture (Ctrl+Shift+W)", em) { history_action(app, .Workflows) }
		if history_icon_button("palette", lucide.COMMAND, "Command palette (Ctrl+K)", em) { history_action(app, .Palette) }
		if history_icon_button("settings", lucide.SETTINGS, "Settings (Ctrl+,)", em) { history_action(app, .Settings) }
		ui.spacer(ui.px(em * 0.6))
	}
}

@(private = "file")
history_icon_button :: proc(id, glyph, tip: string, em: f32) -> bool {
	ui.next({width = ui.px(math.round(em * 2.1)), height = ui.px(math.round(em * 2.1)), font_size = em * 1.15})
	sig := ui.icon_button(id, glyph)
	if ui.hovered_for(sig, 0.5) {
		if ui.tooltip() { ui.tooltip_text(tip) }
	}
	return sig.clicked
}

// The grid, the list, or what stands for them with nothing to show.
@(private = "file")
history_main :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	if len(hw.history.entries) == 0 {
		keys := shortcut_keys(app, .Region)
		note := keys != "" ? fmt.tprintf("Press %s, or click cliche's icon in the notification area: each capture comes here.", keys) : "Click cliche's icon in the notification area, or run cliche --region: each capture comes here."
		if !hw.loaded { note = "Reading the history…" }
		if ui.empty_state("empty", {icon = lucide.HISTORY, title = "No capture yet", note = note, actions = {"Capture a region"}}) == 0 {
			history_action(app, .Capture_Region)
		}
		return
	}
	if len(hw.shown_ids) == 0 {
		if ui.empty_state("nothing", {icon = lucide.SEARCH, title = "Nothing matches", note = "No capture has these words, or is of this kind.", actions = {"Clear the search"}}) == 0 {
			ui.field_set(&hw.search, "")
			hw.filter = .All
			hw.shown_due = true
		}
		return
	}
	switch app.settings.history_view {
	case .Grid: history_grid(app, em)
	case .List: history_list(app, em)
	}
}

@(private = "file")
history_footer :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	if ui.row(id = "###footer") {
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			n := len(hw.selection.marked)
			count := len(hw.shown_ids) == len(hw.history.entries) ? fmt.tprintf("%d captures", len(hw.history.entries)) : fmt.tprintf("%d of %d captures", len(hw.shown_ids), len(hw.history.entries))
			if n > 1 { count = fmt.tprintf("%s, %d selected", count, n) }
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###count", count))
			ui.spacer(ui.px(em * 1.2))
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###status", ui.text_shown(hw.status)))
		}
	}
}

////////////////////////////////
// The grid

@(private = "file")
History_Thumb_Draw :: struct { tex: render.Texture, size: [2]f32, radius: f32, dim: bool }

@(private = "file")
history_grid :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	step := clamp(app.settings.history_thumbnail, 0, 2)
	cell := math.round(em * HISTORY_CELL_EM[step])
	gap := math.round(em * 0.7)
	line_h := cell + math.round(em * 3.4) + gap
	// (the width of the last build: the cells per line follow the window)
	width := f32(HISTORY_WINDOW_SIZE.x)
	if b := ui.box_from_key(hw.grid.key); b != nil && b.size.x > 0 { width = b.size.x }
	columns := max(1, int((width - gap - em) / (cell + gap)))
	if columns != hw.grid_columns || len(hw.grid_rows) == 0 { history_grid_lines(hw, columns) }
	if hw.grid_reveal {
		hw.grid_reveal = false
		if at := history_selection_place(&hw.selection, hw.shown_ids[:]); at >= 0 { ui.list_select(&hw.grid, at / columns) }
	}
	n := len(hw.shown_ids)
	ui.next({width = ui.fill(), height = ui.fill()})
	if rows, ok := ui.vlist("###grid", &hw.grid, hw.grid_rows[:], ids_version = hw.grid_version); ok {
		for r in rows.first ..< rows.last {
			// (the id the virtual list measures a line by)
			ui.next({width = ui.fill(), height = ui.px(line_h), axis = .X})
			if ui.row(id = fmt.tprintf("###lrow_%d", r)) {
				ui.spacer(ui.px(gap))
				for c in 0 ..< columns {
					i := r * columns + c
					if i >= n { break }
					history_cell(app, i, cell, em)
					ui.spacer(ui.px(gap))
				}
			}
		}
	}
}

// The lines of the grid: one id each (its first entry's, and the count per line: a line of another width is measured anew).
@(private = "file")
history_grid_lines :: proc(hw: ^History_Window, columns: int) {
	hw.grid_columns = columns
	n := len(hw.shown_ids)
	lines := (n + columns - 1) / columns
	resize(&hw.grid_rows, lines)
	for r in 0 ..< lines { hw.grid_rows[r] = hw.shown_ids[r * columns] ~ (u64(columns) << 56) }
	hw.grid_version += 1
}

// The cell of the entry shown at `i`: its thumbnail (or an icon, or its text's first words), its name, its time.
@(private = "file")
history_cell :: proc(app: ^App, i: int, cell, em: f32) {
	hw := &app.history_window
	e := hw.history.entries[hw.shown[i]]
	selected := e.id in hw.selection.marked
	focused := !ui.inactive()
	ui.next({width = ui.px(cell), height = ui.pct(1), axis = .Y, radius = em * 0.4})
	flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects, .Hot_Within}
	if selected { flags += {.Draw_Background} }
	ui.push_tags(selected ? (focused ? "selected" : "weak_selected") : "list_row")
	b := ui.build_box(flags, fmt.tprintf("###cell_%d", e.id))
	ui.pop_tags()
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.3))
		history_cell_picture(app, e, cell, em)
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), text_pad = em * 0.3, text_align = .Center})
		ui.label(fmt.tprintf("%s###name", ui.text_shown(history_name(e))))
		if ui.tags(e.missing ? "bad" : "weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.3)), text_pad = em * 0.3, text_align = .Center, font_size = math.round(em * 0.85)})
			ui.label(fmt.tprintf("%s###when", e.missing ? "File missing" : history_time_text(hw, e.time_ms)))
		}
	}
	if sig.pressed {
		how := History_Click.Alone
		if .Ctrl in sig.mods { how = .Toggle } else if .Shift in sig.mods { how = .Range }
		history_selection_click(&hw.selection, hw.shown_ids[:], e.id, how)
		hw.table_give = true
	}
	if sig.double_clicked { history_action(app, .Open) }
	if sig.right_clicked {
		if e.id not_in hw.selection.marked { history_select_one(&hw.selection, e.id); hw.table_give = true }
		ui.ctx_menu_open(hw.menu_key, ui.mouse_pos())
	}
}

@(private = "file")
history_cell_picture :: proc(app: ^App, e: History_Entry, cell, em: f32) {
	hw := &app.history_window
	if e.kind == .Qr || e.kind == .Text {
		ui.next({width = ui.px(cell), height = ui.px(cell), radius = em * 0.3, font_size = math.round(em * 0.85), text_pad = em * 0.5})
		if ui.tags("weak") {
			ui.build_box({.Draw_Text, .Text_Wrap, .Clip}, fmt.tprintf("%s###text", ui.text_shown(history_first_words(e.text, 160))))
		}
		return
	}
	t := history_thumb(app, e)
	if t != nil && t.state == .Ready {
		d := ui.frame_new(History_Thumb_Draw)
		d^ = {tex = t.tex, size = {f32(t.size.x), f32(t.size.y)}, radius = em * 0.25, dim = e.missing}
		ui.next({width = ui.px(cell), height = ui.px(cell)})
		ui.custom("###thumb", history_thumb_draw, d)
		return
	}
	glyph := e.kind == .Video || e.kind == .Gif ? lucide.FILM : lucide.IMAGE
	if e.missing { glyph = lucide.FILE }
	ui.next({width = ui.px(cell), height = ui.px(cell), font = hw.icons, font_size = math.round(em * 2.4), text_align = .Center, fg = ui.color("weak text")})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###thumb", glyph))
}

// The picture fitted in its cell, in the middle.
@(private = "file")
history_thumb_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^History_Thumb_Draw)(user)
	r := b.rect
	view := r.max - r.min
	if d.size.x <= 0 || d.size.y <= 0 || view.x <= 0 || view.y <= 0 { return }
	k := min(view.x / d.size.x, view.y / d.size.y)
	shown := d.size * k
	lo := r.min + (view - shown) * 0.5
	dst := ui.Rect{{math.round(lo.x), math.round(lo.y)}, {math.round(lo.x + shown.x), math.round(lo.y + shown.y)}}
	draw.image(dc, d.tex, dst, tint = d.dim ? draw.Color{1, 1, 1, 0.45} : draw.WHITE, radius = d.radius)
}

// The entry's thumbnail as known now; asked of the worker the first time it is in view (a few at once).
@(private = "file")
history_thumb :: proc(app: ^App, e: History_Entry) -> ^History_Texture {
	hw := &app.history_window
	if t, found := &hw.thumbs[e.id]; found {
		t.seen = hw.frame
		return t
	}
	if e.path == "" || e.missing || hw.thumbs_asked >= HISTORY_THUMBS_IN_FLIGHT { return nil }
	hw.thumbs[e.id] = {state = .Asked, seen = hw.frame}
	hw.thumbs_asked += 1
	picture := e.kind == .Region || e.kind == .Screen || e.kind == .Window
	worker_send(&app.worker, Job_History(History_Thumb_Ask{id = e.id, path = strings.clone(e.path), size = HISTORY_THUMB_ASK, picture = picture}))
	return &hw.thumbs[e.id]
}

@(private = "file")
history_thumb_drop :: proc(app: ^App, id: u64) {
	hw := &app.history_window
	if t, found := hw.thumbs[id]; found && t.state == .Ready { render.destroy_texture(&app.shared.r, t.tex) }
	delete_key(&hw.thumbs, id)
}

@(private = "file")
history_textures_drop :: proc(app: ^App) {
	hw := &app.history_window
	for _, t in hw.thumbs {
		if t.state == .Ready { render.destroy_texture(&app.shared.r, t.tex) }
	}
	// (the thumbnails asked stay counted until their results come: they are dropped then)
	clear(&hw.thumbs)
	history_preview_drop(app)
}

////////////////////////////////
// The list

@(private = "file")
history_list :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	t := &hw.table
	if hw.table_due {
		hw.table_due = false
		ui.table_data_reset(&hw.table_data, len(History_Column))
		for p in hw.shown {
			e := hw.history.entries[p]
			name := history_name(e)
			ui.table_data_row(&hw.table_data, e.id, name, e.missing ? .Dim : .Normal)
			ui.table_data_cell(&hw.table_data, e.missing ? fmt.tprintf("%s (missing)", name) : name)
			ui.table_data_cell(&hw.table_data, HISTORY_KIND_TEXT[e.kind])
			ui.table_data_cell(&hw.table_data, history_size_text(e), f64(e.bytes) + f64(e.size.x * e.size.y) * 1e-9)
			ui.table_data_cell(&hw.table_data, history_time_text(hw, e.time_ms), f64(e.time_ms))
			ui.table_data_cell(&hw.table_data, e.url)
		}
		// (filtered already: the table's own filter is given nothing, its highlight is the search)
		ui.table_apply(t, &hw.table_data, "")
		t.highlight = hw.query
	}
	if hw.table_give {
		hw.table_give = false
		ui.list_marks_clear(&t.vl)
		if len(hw.selection.marked) > 1 { for id in hw.selection.marked { t.vl.marks[id] = true } }
		if hw.selection.focus != 0 { ui.table_select_id(t, hw.selection.focus) }
	}
	dialog := hw.palette.open || hw.sheet_open || hw.confirm_open || ui.ctx_menu_any_open()
	keys: ui.Table_Events
	if !dialog { keys = ui.table_keys(t) }
	ui.next({width = ui.fill(), height = ui.fill()})
	ev := ui.table_build("###list", t, &hw.table_data, "")
	if ev.sorted {
		if t.sort == ui.TABLE_UNSORTED {
			hw.sort, hw.descending = .Date, true
		} else {
			hw.sort, hw.descending = History_Column(t.sort), t.descending
		}
		hw.shown_due = true
	}
	if t.vl.changed || t.vl.marks_changed || keys != {} || ev.menu { history_take_table_selection(app) }
	if ev.activated || keys.activated { history_action(app, .Open) }
	if ev.menu || keys.menu {
		at := ev.menu ? ev.menu_at : keys.menu_at
		ui.ctx_menu_open(hw.menu_key, at, from_keyboard = ev.keyboard || keys.keyboard)
	}
}

// The table's selection, copied into the model's (the actions read that one).
@(private = "file")
history_take_table_selection :: proc(app: ^App) {
	hw := &app.history_window
	t := &hw.table
	clear(&hw.selection.marked)
	for id, on in t.vl.marks { if on { hw.selection.marked[id] = {} } }
	focus: u64
	if t.vl.sel >= 0 && t.vl.sel < len(t.ids) { focus = t.ids[t.vl.sel] }
	if len(hw.selection.marked) == 0 && focus != 0 { hw.selection.marked[focus] = {} }
	hw.selection.focus = focus
	if hw.selection.anchor == 0 { hw.selection.anchor = focus }
	hw.selection.version += 1
}

// The kind's icon before a row's name.
@(private = "file")
history_table_lead :: proc(t: ^ui.Table, row: int, size: f32) {
	app := (^App)(t.lead_user)
	hw := &app.history_window
	if row < 0 || row >= len(hw.shown) { return }
	e := hw.history.entries[hw.shown[row]]
	glyph := lucide.IMAGE
	switch e.kind {
	case .Region, .Screen, .Window: glyph = lucide.IMAGE
	case .Video, .Gif:              glyph = lucide.FILM
	case .Qr:                       glyph = lucide.QR_CODE
	case .Text:                     glyph = lucide.FILE_TEXT
	}
	fg: Maybe(ui.Color)
	if e.missing { fg = ui.color("weak text") }
	ui.icon(glyph, size, fg)
}

////////////////////////////////
// The preview

@(private = "file")
history_preview_pane :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	ui.next({width = ui.px(math.round(em * app.settings.history_preview_em)), height = ui.fill(), axis = .Y})
	if ui.column(id = "###preview_pane") {
		e := history_find(&hw.history, hw.selection.focus)
		if e == nil {
			ui.empty_state("no_preview", {icon = lucide.EYE, title = "Nothing selected", note = "Select a capture to see it here."})
			return
		}
		picture := e.kind == .Region || e.kind == .Screen || e.kind == .Window
		ui.next({width = ui.fill(), height = ui.fill()})
		switch {
		case picture && !e.missing:
			if hw.preview_id != e.id && hw.preview_asked != e.id {
				hw.preview_asked = e.id
				worker_send(&app.worker, Job_History(History_Picture_Ask{id = e.id, path = strings.clone(e.path), purpose = .Preview}))
			}
			if hw.preview_id == e.id {
				ui.preview_image("###preview", &hw.preview, hw.preview_tex, {f32(hw.preview_size.x), f32(hw.preview_size.y)}, {buttons = true, radius = 6})
			} else {
				ui.empty_state("loading", {icon = lucide.LOADER, title = "Reading the picture…"})
			}
		case e.kind == .Qr || e.kind == .Text:
			if ui.scroll_y("###preview_text") {
				ui.next({width = ui.fill(), text_pad = em * 0.8})
				ui.paragraph(fmt.tprintf("%s###text", ui.text_shown(e.text)))
			}
		case:
			// (a recording: its thumbnail when the system made one)
			t, found := hw.thumbs[e.id]
			if found && t.state == .Ready {
				ui.preview_image("###preview", &hw.preview, t.tex, {f32(t.size.x), f32(t.size.y)}, {radius = 6})
			} else {
				ui.empty_state("no_picture", {icon = e.missing ? lucide.FILE : lucide.FILM, title = e.missing ? "The file is missing" : "No picture", note = e.missing ? e.path : ""})
			}
		}
		history_details(hw, e^, em)
	}
}

// Under the preview: what the entry is, a line each.
@(private = "file")
history_details :: proc(hw: ^History_Window, e: History_Entry, em: f32) {
	ui.hline(ui.fill())
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, history_name(e))
	append(&lines, fmt.tprintf("%s, %s", HISTORY_KIND_TEXT[e.kind], history_time_text(hw, e.time_ms)))
	if s := history_size_text(e); s != "" { append(&lines, s) }
	if e.path != "" { append(&lines, e.missing ? fmt.tprintf("%s (missing)", e.path) : e.path) }
	if e.url != "" { append(&lines, e.url) }
	ui.spacer(ui.px(em * 0.4))
	for line, i in lines {
		if i == 0 {
			ui.next({width = ui.fill(), text_pad = em * 0.8})
			ui.paragraph(fmt.tprintf("%s###detail%d", ui.text_shown(line), i))
			continue
		}
		if ui.tags("weak") {
			ui.next({width = ui.fill(), text_pad = em * 0.8, font_size = math.round(em * 0.86)})
			ui.paragraph(fmt.tprintf("%s###detail%d", ui.text_shown(line), i))
		}
	}
	ui.spacer(ui.px(em * 0.6))
}

@(private = "file")
history_preview_drop :: proc(app: ^App) {
	hw := &app.history_window
	if hw.preview_id != 0 { render.destroy_texture(&app.shared.r, hw.preview_tex) }
	hw.preview_id, hw.preview_tex, hw.preview_size = 0, {}, {}
	hw.preview_asked = 0
}

////////////////////////////////
// Keys, menu, palette, actions

@(private = "file")
history_keys :: proc(app: ^App) {
	hw := &app.history_window
	enabled := history_enabled(app)
	for a in History_Action {
		if hw.search_focused && a in HISTORY_FIELD_KEYS { continue }
		if ui.command_pressed(HISTORY_ACTIONS[a], a in enabled) { history_action(app, a); return }
	}
	if hw.settings_mode.open || app.settings.history_view != .Grid || len(hw.shown_ids) == 0 { return }
	// the grid's moves: a line is `grid_columns` cells; Shift extends the selection (the move clamps to the ends)
	columns := max(hw.grid_columns, 1)
	page := columns * max(hw.grid.page_rows - 1, 1)
	extends := [2]bool{false, true}
	for extend in extends {
		mods: platform.Modifiers = extend ? {.Shift} : {}
		// (the step first: the focus's place is looked for only when a key moves it)
		step, moved := 0, true
		switch {
		case !hw.search_focused && ui.key_press(.Left, mods):  step = -1
		case !hw.search_focused && ui.key_press(.Right, mods): step = 1
		case !hw.search_focused && ui.key_press(.Home, mods):  step = min(int)
		case !hw.search_focused && ui.key_press(.End, mods):   step = max(int)
		case ui.key_press(.Up, mods):        step = -columns
		case ui.key_press(.Down, mods):      step = columns
		case ui.key_press(.Page_Up, mods):   step = -page
		case ui.key_press(.Page_Down, mods): step = page
		case: moved = false
		}
		if !moved { continue }
		at := history_selection_place(&hw.selection, hw.shown_ids[:])
		to := 0
		switch {
		case at < 0:          to = 0   // (nothing selected: the first entry)
		case step == min(int): to = 0
		case step == max(int): to = len(hw.shown_ids) - 1
		case:                 to = at + step
		}
		history_selection_move(&hw.selection, hw.shown_ids[:], to, extend)
		hw.grid_reveal = true
		hw.table_give = true
		return
	}
}

@(private = "file")
history_menu :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	if ui.ctx_menu(hw.menu_key, em * 17) {
		enabled := history_enabled(app)
		for a in HISTORY_MENU {
			if a in HISTORY_MENU_BREAKS { ui.menu_separator() }
			c := HISTORY_ACTIONS[a]
			if ui.menu_item(c.label, ui.chord_text(c.keys[0]), false, c.icon, a in enabled, icon_font = hw.icons).clicked { history_action(app, a) }
		}
	}
}

// The palette (the history's actions, the settings' actions, then every setting), the sheet of keys, the question
// before files are deleted.
@(private = "file")
history_dialogs :: proc(app: ^App) {
	hw := &app.history_window
	history_commands := slice.enumerated_array(&HISTORY_ACTIONS)
	settings_commands := slice.enumerated_array(&SETTINGS_ACTIONS)
	if hw.palette.open {
		set := history_enabled(app)
		mine := make([]bool, len(History_Action), context.temp_allocator)
		for a in History_Action { mine[int(a)] = a in set }
		theirs, theirs_enabled, names := settings_palette(app)
		// (the Workflows mode's own commands, last, while it is shown)
		flows := hw.workflow_mode.open ? slice.enumerated_array(&WORKFLOW_ACTIONS) : nil
		flows_enabled := make([]bool, len(flows), context.temp_allocator)
		for &e in flows_enabled { e = true }
		commands := slice.concatenate([][]ui.Command{history_commands, theirs, flows}, context.temp_allocator)
		enabled := slice.concatenate([][]bool{mine, theirs_enabled, flows_enabled}, context.temp_allocator)
		if i, _ := ui.palette(&hw.palette, commands, enabled); i >= 0 {
			switch {
			case i < len(History_Action):               history_action(app, History_Action(i))
			case i < len(History_Action) + len(theirs): settings_palette_chosen(app, i - len(History_Action), names)
			case:                                       workflow_action(app, Workflow_Action(i - len(History_Action) - len(theirs)))
			}
		}
	}
	sheet := slice.concatenate([][]ui.Command{history_commands, settings_commands, slice.enumerated_array(&WORKFLOW_ACTIONS)}, context.temp_allocator)
	ui.shortcuts_sheet("keys", sheet, &hw.sheet_open, "cliche's keys")
	if hw.confirm_open {
		names := make([dynamic]string, context.temp_allocator)
		for id in hw.delete_ids {
			if e := history_find(&hw.history, id); e != nil { append(&names, e.path) }
		}
		title := fmt.tprintf("Delete %d files for good?", len(names))
		if len(names) == 1 { title = fmt.tprintf("Delete %s for good?", names[0][strings.last_index_any(names[0], "/\\") + 1:]) }
		switch ui.confirm("delete", &hw.confirm_open, {title = title, note = "The files go from the disk, not to the trash. Their lines stay in the history, marked missing.", lines = names[:], act = "Delete"}) {
		case .Confirmed:
			worker_send(&app.worker, Job_History(History_Delete{ids = clone_ids(hw.delete_ids[:])}))
			history_status(hw, len(names) == 1 ? "The file is deleted" : fmt.tprintf("%d files are deleted", len(names)))
			clear(&hw.delete_ids)
		case .Cancelled:
			clear(&hw.delete_ids)
		case .None:
		}
	}
}

// The entries the actions act on: the selection, in the order shown.
@(private = "file")
history_selected :: proc(app: ^App) -> []u64 {
	hw := &app.history_window
	return history_selection_ids(&hw.selection, hw.shown_ids[:])
}

// The actions that can act now. Made again only when the entries, the selection or the view changed: it passes over
// the selection, which Ctrl+A makes as large as the history.
@(private = "file")
history_enabled :: proc(app: ^App) -> History_Actions {
	hw := &app.history_window
	settings := hw.settings_mode.open || hw.workflow_mode.open
	stamp := [3]u64{hw.history.version, hw.selection.version, u64(app.settings.history_view) + u64(len(hw.shown_ids)) << 8 + u64(settings) << 62}
	if stamp == hw.enabled_stamp && hw.enabled_made { return hw.enabled }
	hw.enabled_stamp, hw.enabled_made = stamp, true
	// (on the settings: what concerns the window alone; the history's actions wait for it)
	window := History_Actions{.Open_Folder, .Capture_Region, .Workflows, .Settings, .Palette, .Keys, .Close, .Quit}
	if settings {
		hw.enabled = window
		return window
	}
	out := window + {.Preview, .Search}
	if app.settings.history_view == .Grid { out += {.List} } else { out += {.Grid} }
	if len(hw.shown_ids) > 0 { out += {.Select_All} }
	if len(hw.selection.marked) > 0 { out += {.Remove} }
	for id in hw.selection.marked {
		e := history_find(&hw.history, id)
		if e == nil { continue }
		if e.path != "" { out += {.Copy_Path} }
		if e.path != "" && !e.missing { out += {.Open, .Reveal, .Delete_File} }
		if history_is_picture(e^) && !e.missing { out += {.Upload} }
		if e.url != "" { out += {.Copy_Url} }
		if e.text != "" { out += {.Copy_Text} }
	}
	if e := history_find(&hw.history, hw.selection.focus); e != nil && history_is_picture(e^) && !e.missing { out += {.Copy_Picture, .Edit} }
	hw.enabled = out
	return out
}

@(private = "file")
history_is_picture :: proc(e: History_Entry) -> bool {
	return e.path != "" && (e.kind == .Region || e.kind == .Screen || e.kind == .Window)
}

@(private = "file")
history_action :: proc(app: ^App, a: History_Action) {
	hw := &app.history_window
	if a not_in history_enabled(app) { return }
	ids := history_selected(app)
	focus := history_find(&hw.history, hw.selection.focus)
	switch a {
	case .Open:
		opened := 0
		for id in ids {
			e := history_find(&hw.history, id)
			if e == nil || e.path == "" || e.missing { continue }
			worker_send(&app.worker, Job_History(History_Open{path = strings.clone(e.path)}))
			opened += 1
			if opened == HISTORY_OPEN_MAX { break }
		}
	case .Reveal:
		for id in ids {
			if e := history_find(&hw.history, id); e != nil && e.path != "" && !e.missing {
				worker_send(&app.worker, Job_Reveal{path = strings.clone(e.path)})
				break
			}
		}
	case .Copy_Picture:
		worker_send(&app.worker, Job_History(History_Picture_Ask{id = focus.id, path = strings.clone(focus.path), purpose = .Copy}))
	case .Copy_Path:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.path }, "\n", "The path is on the clipboard", "The paths are on the clipboard")
	case .Copy_Url:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.url }, "\n", "The URL is on the clipboard", "The URLs are on the clipboard")
	case .Copy_Text:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.text }, "\n\n", "The text is on the clipboard", "The texts are on the clipboard")
	case .Edit:
		editor_open_file(app, focus.path)
	case .Upload:
		for id in ids {
			e := history_find(&hw.history, id)
			if e == nil || !history_is_picture(e^) || e.missing { continue }
			worker_send(&app.worker, Job_History(History_Upload{id = e.id, path = strings.clone(e.path), uploader = strings.clone(app.settings.uploader)}))
		}
		history_status(hw, "Uploading…")
	case .Delete_File:
		clear(&hw.delete_ids)
		for id in ids {
			if e := history_find(&hw.history, id); e != nil && e.path != "" && !e.missing { append(&hw.delete_ids, id) }
		}
		hw.confirm_open = len(hw.delete_ids) > 0
	case .Remove:
		gone := clone_ids(ids)
		history_remove(&hw.history, gone)
		worker_send(&app.worker, Job_History(History_Remove{ids = gone}))
		history_status(hw, len(gone) == 1 ? "Removed from the history (the file stays)" : fmt.tprintf("%d removed from the history (the files stay)", len(gone)))
	case .Preview:
		hw.preview_open = !hw.preview_open
		if !hw.preview_open { history_preview_drop(app) }
	case .Select_All:
		if app.settings.history_view == .List {
			ui.list_mark_all(&hw.table.vl)
			history_take_table_selection(app)
		} else {
			history_selection_all(&hw.selection, hw.shown_ids[:])
		}
	case .Search:
		if hw.search_key != 0 { ui.set_focus(hw.search_key) }
	case .Grid:
		history_pref(app, "history.view", HISTORY_VIEW_NAMES[.Grid])
	case .List:
		history_pref(app, "history.view", HISTORY_VIEW_NAMES[.List])
	case .Open_Folder:
		worker_send(&app.worker, Job_Open_Folder{folder = strings.clone(app.settings.folder)})
	case .Capture_Region:
		hw.hide_due = true
		app_trigger(app, .Region)
	case .Workflows:
		workflow_mode_enter(app)
	case .Settings:
		workflow_mode_leave(app)
		settings_enter(app)
	case .Palette:
		ui.palette_open(&hw.palette)
	case .Keys:
		hw.sheet_open = true
	case .Close:
		hw.hide_due = true
	case .Quit:
		app.quit = true
	}
}

// The texts of the entries selected, joined, on the clipboard.
@(private = "file")
history_copy_text :: proc(app: ^App, ids: []u64, field: proc(e: ^History_Entry) -> string, separator, one, several: string) {
	hw := &app.history_window
	parts := make([dynamic]string, context.temp_allocator)
	for id in ids {
		if e := history_find(&hw.history, id); e != nil && field(e) != "" { append(&parts, field(e)) }
	}
	if len(parts) == 0 { return }
	if platform.clipboard_set(app.anchor, {text = strings.join(parts[:], separator, context.temp_allocator)}) {
		history_status(hw, len(parts) == 1 ? one : several)
	}
}

// A preference of the history set from the window (written by the worker, applied by app_prefs_changed).
@(private = "file")
history_pref :: proc(app: ^App, name, value: string) {
	if config.set_from_string(&app.prefs, name, value, .User) == .None { app_prefs_changed(app) }
}

@(private = "file")
history_status :: proc(hw: ^History_Window, text: string) {
	delete(hw.status)
	hw.status = strings.clone(text)
}

@(private = "file")
clone_ids :: proc(ids: []u64) -> []u64 {
	out := make([]u64, len(ids))
	copy(out, ids)
	return out
}

////////////////////////////////
// Words

// "14:32" today, "Nov 10 14:32" before.
@(private = "file")
history_time_text :: proc(hw: ^History_Window, time_ms: i64) -> string {
	ms := f64(time_ms)
	clock := timefmt.clock(ms, hw.offset_minutes)
	if timefmt.local_day(ms, hw.offset_minutes) == hw.today { return clock }
	return fmt.tprintf("%s %s", timefmt.date(ms, hw.offset_minutes), clock)
}

// "1920 × 1080, 245 KB"; a recording's bytes and length; nothing for a text.
history_size_text :: proc(e: History_Entry) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if e.size.x > 0 && e.size.y > 0 { append(&parts, fmt.tprintf("%d × %d", e.size.x, e.size.y)) }
	if e.bytes > 0 { append(&parts, size_text(e.bytes)) }
	if e.length_ms > 0 { append(&parts, record_elapsed_text(e.length_ms)) }
	return strings.join(parts[:], ", ", context.temp_allocator)
}
