package cliche

// cliche's main window, the history: the captures kept (history.odin), in a grid of thumbnails or in a list, with a
// search, a filter by kind and one by date, a preview of the picture selected (Space) and the usual actions: open, open
// the address, show in its folder, copy, edit, upload again, combine pictures into one, delete the file, forget the
// entry. The tray's Recent submenu is made here too (tray_recent_items). The settings show in it, in place of the history
// (settings_view.odin): the gear of the toolbar and Ctrl+, open them, the back bar and Escape go back. Made at its first
// show, hidden at a close, in the theme of appearance.theme, with the command palette (Ctrl+K) and the sheet of keys
// (F1) of both modes.
//
// What is slow goes to the worker (history.odin's jobs): the file, the thumbnails, a picture decoded, an upload, a file
// opened or deleted. A thumbnail is a texture only while its entry is in view: the grid is a virtual list of lines of
// cells, and the textures of the entries not built in the last frames are freed after each frame.
//
// One selection for the grid and the list: the toolkit's Item_Selection, multi (src/md/features/history-selection.md).
// It is the list's table's (Table.vl.selection); the grid calls the same model with its rows and its moves by columns.
// The acts on entries take every entry selected; those that show or open one picture take the cursor's.

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import config "gt:config"
import "gt:draw"
import "gt:font"
import host "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import crash_bar "gt:crash_bar"
import "gt:render"
import setup "gt:setup"
import timefmt "gt:timefmt"
import "gt:ui"
import i18n "gt:i18n"

HISTORY_WINDOW_SIZE :: [2]int{1000, 680}

// The thumbnails asked of the system: its "large" cache (256 pixels), enough for the largest cell.
HISTORY_THUMB_ASK :: 256
// Thumbnails asked of the worker at once: a fast scroll does not queue the whole history behind the next job.
HISTORY_THUMBS_IN_FLIGHT :: 6
// Frames a texture stays after its entry left the view (a scroll back finds it).
HISTORY_THUMB_KEEP_FRAMES :: 30
// The side of a thumbnail's cell per step of history.thumbnail_size, in ems.
HISTORY_CELL_EM := [3]f32{7, 10, 14}
// A row of the list per step of history.thumbnail_size, in ems: its thumbnail as high, less a margin.
HISTORY_ROW_EM := [3]f32{2.6, 3.6, 5}
// A list's thumbnail is this much wider than high (most screens' shape).
HISTORY_ROW_THUMB_ASPECT :: 1.6
// The preview's pane (the view PREVIEW_VIEW), in ems: its width when first docked, and its least width.
HISTORY_PREVIEW_EM     :: 26
HISTORY_PREVIEW_MIN_EM :: 14
// The dock space of the history's page, around its grid or list: the preview's home. It is built only while the history
// shows, so the preview steps aside in the settings and the workflows (src/md/features/views.md).
HISTORY_SPACE :: "history"
// Entries an action opens at once (each starts a program).
HISTORY_OPEN_MAX :: 8

History_View_Mode :: enum u8 { Grid, List }

HISTORY_VIEW_NAMES := [History_View_Mode]string{.Grid = "grid", .List = "list"}
HISTORY_THUMBNAIL_NAMES := [3]string{"small", "medium", "large"}

// The history's context menu (history_menu).
HISTORY_MENU_ID :: "history_menu"

// The list's columns, in the order of History_Column.
HISTORY_COLUMNS := [History_Column]ui.Table_Column{
	.Name = {title = i18n.later("Name"), width = 0},
	.Kind = {title = i18n.later("Kind"), width = 7},
	.Size = {title = i18n.later("Size"), width = 13, number = true},
	.Date = {title = i18n.later("Date"), width = 10, number = true},
	.Url  = {title = i18n.later("URL"), width = 18, weak = true},
}

History_Thumb_State :: enum u8 { Asked, Ready, None }

History_Texture :: struct {
	state: History_Thumb_State,
	tex:   render.Texture,
	size:  [2]int,
	seen:  u64,   // the last frame its entry was built
}

// The palette's commands: the history's actions, the settings' actions, then the Workflows mode's (listed while it is
// shown).
HISTORY_PALETTE_COUNT :: len(History_Action) + len(Settings_Action) + len(Workflow_Action)

// What can act now, as the palette's commands source was last given it: a change is a new version of the source.
History_Palette_Can :: struct {
	actions:  History_Actions,
	settings: bit_set[Settings_Action],
}

History_Window :: struct {
	host:        host.Host,
	opened:      bool,
	visible:     bool,
	hide_due:    bool,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	// the palette (src/palette.odin): the commands, the views' moves and the settings, the toolkit's; the captures and
	// the workflows, cliche's
	palette:     ui.Command_Palette,
	palette_commands: [HISTORY_PALETTE_COUNT]ui.Command,   // the commands source's table (made once)
	palette_disabled: [HISTORY_PALETTE_COUNT]bool,
	palette_can:      History_Palette_Can,                 // what `palette_disabled` says
	palette_version:  u64,                                 // raised when it changes
	palette_settings: prefs_page.Palette_Settings,   // the settings source: its page options read when it reads
	captures:    ui.Palette_Source,   // `@`
	workflows_source: ui.Palette_Source,   // `#`
	sheet:       ui.Shortcuts_Sheet,
	sheet_table: Command_Table,       // the sheet's commands (history_sheet_keep)
	sheet_language: u32,          // i18n.version() they were made in

	history:     History,         // the interface's copy (history.odin)
	loaded:      bool,            // the file was read
	offset_minutes: int,          // the local time's, read by the worker

	search:      ui.Line_Edit,
	search_key:  ui.Key,
	search_focused: bool,
	query:       string,          // the search the entries shown were made with (owned)
	filter:      History_Filter,
	period:      History_Period,  // the filter by date
	sort:        History_Column,
	descending:  bool,
	shown:       [dynamic]int,    // places in history.entries, in the order shown
	shown_ids:   [dynamic]u64,
	shown_version: u64,           // history.version the lists were made at
	shown_due:   bool,            // the search, the filter or the sort changed
	// the selection's rows changed, or are another view's: settled where they are fresh (history_rows_settle)
	rows_due:    bool,            // the rows changed: the ids gone leave the selection
	cursor_due:  bool,            // the cursor goes back to `cursor_id` in the new rows
	cursor_id:   u64,
	select_due:  u64,             // the entry selected alone once it is shown (a new one, the tray's; 0: none)

	table:       ui.Table,        // the list; its List_State's selection is the window's (history_selection)
	table_data:  ui.Table_Data,
	table_due:   bool,            // the table's rows are made again at its next build
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

	preview:     ui.Preview,
	preview_id:  u64,             // the entry of preview_tex (0: none)
	preview_asked: u64,
	preview_tex: render.Texture,
	preview_size: [2]int,

	enabled:     History_Actions,   // history_enabled's, as of `enabled_stamp`
	enabled_stamp: [4]u64,
	enabled_made: bool,

	settings_mode: Settings_Mode,   // settings_view.odin
	workflow_mode: Workflow_Mode,   // workflow_view.odin
	delete_ids:  [dynamic]u64,    // the files the question HISTORY_DELETE_VIEW asks about
	setup_due:   bool,            // the setup's view opens at the next build (asked outside one: cliche --setup)
	status:      string,          // what the last action did, under the view (owned)
}

// The actions of the palette, the menu, the sheet of keys.
History_Action :: enum u8 {
	Open, Open_Url, Reveal, Copy_Picture, Copy_Path, Copy_Url, Copy_Text, Edit, Pin, Upload, Combine_Side, Combine_Stack, Delete_File, Remove,
	Preview, Select_All, Search, Period, Grid, List, Open_Folder, Capture_Region, Workflows, Settings, Keys, Close, Quit,
}

// (the ids: the person's keys and aliases, and the palette's memory, are stored by them. One id in two tables is one
// command: the history and the editor share "copy", "pin", "upload", "select_all", "shortcuts" and "close", which do
// the same there)
HISTORY_ACTIONS := [History_Action]ui.Command{
	.Open           = {id = "open", label = i18n.later("Open"), group = i18n.later("Capture"), keys = {{.Return, {}}}, icon = lucide.EXTERNAL_LINK, tags = {"view", "launch"}},
	.Open_Url       = {id = "open_url", label = i18n.later("Open the URL"), group = i18n.later("Capture"), keys = {{.Return, {.Shift}}}, icon = lucide.LINK, tags = {"browser", "address", "link", "upload", "web"}},
	.Reveal         = {id = "reveal", label = i18n.later("Open the folder"), group = i18n.later("Capture"), keys = {{.Return, {.Ctrl}}}, icon = lucide.FOLDER_OPEN, tags = {"reveal", "show", "file manager", "explorer"}},
	.Copy_Picture   = {id = "copy", label = i18n.later("Copy the picture"), group = i18n.later("Capture"), keys = {{.C, {.Ctrl}}}, icon = lucide.COPY, tags = {"clipboard", "image"}},
	.Copy_Path      = {id = "copy_path", label = i18n.later("Copy the path"), group = i18n.later("Capture"), keys = {{.C, {.Ctrl, .Shift}}}, icon = lucide.CLIPBOARD_COPY, tags = {"clipboard", "file", "location"}},
	.Copy_Url       = {id = "copy_url", label = i18n.later("Copy the URL"), group = i18n.later("Capture"), keys = {{.L, {.Ctrl}}}, icon = lucide.LINK, tags = {"clipboard", "address", "link", "upload"}},
	.Copy_Text      = {id = "copy_text", label = i18n.later("Copy the text"), group = i18n.later("Capture"), keys = {{.T, {.Ctrl}}}, icon = lucide.FILE_TEXT, tags = {"clipboard", "ocr", "qr"}},
	.Edit           = {id = "edit", label = i18n.later("Edit"), group = i18n.later("Capture"), keys = {{.E, {.Ctrl}}}, icon = lucide.PENCIL, tags = {"editor", "annotate", "draw"}},
	// (no key: Ctrl+T is Copy the text here; the editor's Pin keeps Ctrl+T)
	.Pin            = {id = "pin", label = i18n.later("Pin to the screen"), group = i18n.later("Capture"), icon = lucide.PIN, tags = {"float", "on top", "sticky", "keep", "window"}},
	.Upload         = {id = "upload", label = i18n.later("Upload again"), group = i18n.later("Capture"), keys = {{.U, {.Ctrl}}}, icon = lucide.SEND_HORIZONAL, tags = {"share", "host", "link"}},
	.Combine_Side   = {id = "combine_side", label = i18n.later("Combine side by side"), group = i18n.later("Capture"), icon = lucide.COLUMNS_2, tags = {"join", "merge", "stitch", "horizontal", "together"}},
	.Combine_Stack  = {id = "combine_stack", label = i18n.later("Combine stacked"), group = i18n.later("Capture"), icon = lucide.ROWS_2, tags = {"join", "merge", "stitch", "vertical", "together"}},
	.Delete_File    = {id = "delete_file", label = i18n.later("Delete the file…"), group = i18n.later("Capture"), keys = {{.Delete, {.Shift}}}, icon = lucide.TRASH_2, tags = {"erase", "remove", "disk"}},
	.Remove         = {id = "remove", label = i18n.later("Remove from the history"), group = i18n.later("Capture"), keys = {{.Delete, {}}}, icon = lucide.X, tags = {"forget", "clear"}},
	.Preview        = {id = "preview", label = i18n.later("Preview"), group = i18n.later("View"), keys = {{.Space, {}}}, icon = lucide.EYE, tags = {"zoom", "look"}},
	.Select_All     = {id = "select_all", label = i18n.later("Select all"), group = i18n.later("View"), keys = {{.A, {.Ctrl}}}, icon = lucide.LIST_CHECKS, tags = {"every"}},
	.Search         = {id = "search", label = i18n.later("Search"), group = i18n.later("View"), keys = {{.F, {.Ctrl}}}, icon = lucide.SEARCH, tags = {"find", "filter"}},
	.Period         = {id = "period", label = i18n.later("Show by date…"), group = i18n.later("View"), icon = lucide.CALENDAR, tags = {"date", "today", "week", "month", "filter", "when"}},
	.Grid           = {id = "grid", label = i18n.later("Show a grid"), group = i18n.later("View"), keys = {{.N1, {.Ctrl}}}, icon = lucide.LAYOUT_GRID, tags = {"thumbnails", "pictures"}},
	.List           = {id = "list", label = i18n.later("Show a list"), group = i18n.later("View"), keys = {{.N2, {.Ctrl}}}, icon = lucide.LAYOUT_LIST, tags = {"table", "details", "columns"}},
	.Open_Folder    = {id = "open_folder", label = i18n.later("Open the save folder"), group = i18n.later("View"), icon = lucide.FOLDER_OPEN, tags = {"files", "explorer", "screenshots"}},
	.Capture_Region = {id = "capture_region", label = i18n.later("Capture a region"), group = i18n.later("Window"), icon = lucide.IMAGE, tags = {"screenshot", "new"}},
	.Workflows      = {id = "workflows", label = i18n.later("Workflows"), group = i18n.later("Window"), keys = {{.W, {.Ctrl, .Shift}}}, icon = lucide.GIT_FORK, tags = {"after capture", "steps", "pipeline", "actions", "graph"}, scope = .Window},
	.Settings       = {id = "settings", label = i18n.later("Settings"), group = i18n.later("Window"), keys = {{.Comma, {.Ctrl}}}, icon = lucide.SETTINGS, tags = {"preferences", "options"}, scope = .Window},
	.Keys           = {id = "shortcuts", label = i18n.later("Keyboard shortcuts"), group = i18n.later("Window"), keys = {{.F1, {}}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}, scope = .Window},
	.Close          = {id = "close", label = i18n.later("Close the window"), group = i18n.later("Window"), keys = {{.W, {.Ctrl}}}, icon = lucide.X, tags = {"hide"}, scope = .Window},
	.Quit           = {id = "quit", label = i18n.later("Quit Cliche"), group = i18n.later("Window"), keys = {{.Q, {.Ctrl}}}, icon = lucide.POWER, tags = {"exit", "stop"}, scope = .Window},
}

History_Actions :: bit_set[History_Action]

// The actions whose keys a text field keeps while it has the keyboard (Enter, Space, Ctrl+C, Delete, Ctrl+A...).
HISTORY_FIELD_KEYS :: History_Actions{.Open, .Open_Url, .Copy_Picture, .Copy_Path, .Delete_File, .Remove, .Preview, .Select_All}

// The window's modes (the history, its settings, its workflows: one window).
History_Mode :: enum u8 { History, Settings, Workflows }

// The page's actions whose keys the window reads in `mode` (history_keys); `typing`: a field of the mode has the keyboard
// (a preference's, a workflow's name). The history's actions mean nothing on the settings or the workflows. The window's
// own commands (scope .Window: the palette, the keys, the settings, the workflows, close, quit) are not among them:
// history_window_keys reads them in every mode, whatever has the keyboard.
history_keys_read :: proc(mode: History_Mode, typing: bool) -> History_Actions {
	if mode != .History || typing { return {} }
	read: History_Actions
	for a in History_Action { if HISTORY_ACTIONS[a].scope != .Window { read += {a} } }
	return read
}

// The context menu, in its order; a separator before each of HISTORY_MENU_BREAKS.
@(rodata)
HISTORY_MENU := [?]History_Action{.Open, .Open_Url, .Reveal, .Edit, .Pin, .Copy_Picture, .Copy_Path, .Copy_Url, .Copy_Text, .Upload, .Combine_Side, .Combine_Stack, .Delete_File, .Remove}
HISTORY_MENU_BREAKS :: History_Actions{.Copy_Picture, .Upload, .Combine_Side, .Delete_File}

// The menu of the dates (the toolbar's calendar button).
HISTORY_PERIOD_MENU_ID :: "history_period"

// The newest entries the tray's Recent submenu shows.
TRAY_RECENT_MAX :: 5

////////////////////////////////
// What the app calls

// Reads the file, on the worker: at the start, after worker_start.
history_start :: proc(app: ^App) {
	worker_send(&app.worker, Job_History(History_Load{cap = app.settings.history_size}))
}

// The kind of a screenshot of `source`.
history_kind_of :: proc(source: Source) -> History_Kind {
	switch source {
	case .Region, .Last_Region, .Color: return .Region
	case .Screen, .All_Screens:         return .Screen
	case .Window:                       return .Window
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

// The pictures combined (Combine side by side, stacked): the new picture kept and selected, or why there is none.
history_combined :: proc(app: ^App, r: Result_Combined) {
	r := r
	defer result_combined_free(&r)
	hw := &app.history_window
	history_status(hw, "")
	if r.problem != "" {
		app_announce(app, .Bad, i18n.tr("Not combined"), r.problem, history_window_of(app))
		return
	}
	id := history_note(app, {kind = .Picture, path = r.path, size = r.size, bytes = r.bytes})
	if id != 0 && hw.visible { hw.select_due = id }
	app_announce(app, .Good, i18n.tr("Pictures combined"), r.path, history_window_of(app))
}

// The tray's Recent submenu is out of date: the history changed since it was made.
tray_recent_due :: proc(app: ^App) -> bool {
	return app.tray_recent_version != app.history_window.history.version + 1
}

// The tray's Recent submenu: the newest entries, each by its name and kind (temp allocator; empty: none yet). Their ids
// are kept in app.tray_recent, in the items' order.
tray_recent_items :: proc(app: ^App) -> []platform.Tray_Menu_Item {
	h := &app.history_window.history
	app.tray_recent_version = h.version + 1
	app.tray_recent = {}
	out := make([dynamic]platform.Tray_Menu_Item, 0, TRAY_RECENT_MAX, context.temp_allocator)
	for i := len(h.entries) - 1; i >= 0 && len(out) < TRAY_RECENT_MAX; i -= 1 {
		e := h.entries[i]
		app.tray_recent[len(out)] = e.id
		append(&out, platform.Tray_Menu_Item{id = TRAY_RECENT_ID + len(out), text = fmt.tprintf("%s (%s)", history_first_words(history_name(e), 48), history_kind_text(e.kind))})
	}
	return out[:]
}

// A recent entry chosen in the tray: its address opened, else its file, else it is shown in the history (a text).
tray_recent_chosen :: proc(app: ^App, place: int) {
	if place < 0 || place >= TRAY_RECENT_MAX || app.tray_recent[place] == 0 { return }
	e := history_find(&app.history_window.history, app.tray_recent[place])
	switch {
	case e == nil:                     return   // (removed since)
	case e.url != "":                  ui.open(e.url, .Url)
	case e.path != "" && !e.missing:   ui.open(e.path, .Path)
	case:                              history_window_show(app, e.id)
	}
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
history_settings_read :: proc(p: ^config.Prefs) -> (size: int, view: History_View_Mode, thumbnail: int) {
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
		ui.line_edit_select_all(&hw.search)
		// (a file deleted elsewhere since: its entry shows as missing)
		worker_send(&app.worker, Job_History(History_Check{}))
	}
	if select != 0 { hw.select_due = select }
	platform.raise_window_token(hw.host.win, token)
	hw.host.settle = max(hw.host.settle, 3)
}

// Opens the window (hidden). `headless`: offscreen, on the software renderer (shots.odin).
history_window_open :: proc(app: ^App, headless: bool) -> bool {
	hw := &app.history_window
	if !host.host_open(&hw.host, &app.shared, {title = APP_TITLE, size = HISTORY_WINDOW_SIZE, headless = headless, integrated_title = !app.settings.system_title}, history_build, app) {
		log.error("the main window cannot open")
		return false
	}
	hw.opened = true
	licence_attach(app)   // (the settings' Licence page answers in this window)
	// (the setup's "By" line, in its modal and on the settings' Installation page: a texture of this window's renderer,
	// made before the offer opens the modal)
	if app.install.vendor_mark == nil {
		if mark, ok := setup.logo_make(&app.shared.r, #load("../assets/froment-software-64.png"), {16, 16}); ok { app.install.vendor_mark = mark }
	}
	// (the install read on a task, once the main window is there to show its dialog: offered on Windows; never to a
	// window of the screenshots)
	if !headless && !app.install.known { prefs_page.install_offer(&app.install, &hw.host.state, offer = ODIN_OS == .Windows) }
	// (after an update, once, in this window: a message that stays opens the settings at What's new)
	if !headless && app.changelog.english == "" {
		app.changelog.english = CHANGELOG
		news := ui.Announcer{mode = .Window, state = &hw.host.state}
		prefs_page.changelog_after_update(&app.changelog, &app.prefs, APP_VERSION, &news, proc(user: rawptr) {
			app := (^App)(user)
			settings_show(app)
			prefs_page.show(&app.history_window.settings_mode.page, &app.prefs, settings_options(app), prefs_page.CHANGELOG_PAGE)
		}, app)
	}
	app_standard_follow(app, &hw.host)
	views_window(app, &hw.host)
	// (the preview as the user left it at the last quit; shown at the very first start)
	_ = ui.view_restore(&app.views, PREVIEW_VIEW, app, first_start_open = true, owner = &hw.host.state)
	// (the window's close hides it)
	hw.host.close_asked = proc(h: ^host.Host) { (^App)(h.user).history_window.hide_due = true }
	hw.host.params = history_params
	hw.host.after_input = 3
	hw.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	hw.host.state.icon_font = hw.icons
	hw.sort, hw.descending = .Date, true
	ui.table_init(&hw.table, slice.enumerated_array(&HISTORY_COLUMNS), int(History_Column.Date), descending = true)
	hw.table.vl.multi = true
	hw.table.lead = history_table_lead
	hw.table.lead_user = app
	hw.grid.sel = -1
	hw.grid.no_typeahead = true
	hw.table.vl.no_typeahead = true
	// (the palette remembers the choices of the commands, the settings, the captures and the workflows: its Recent)
	ui.palette_memory_open(&hw.palette, &hw.host.state, palette_choices_path(PALETTE_CHOICES_FILE, headless))
	app_wake_add(app, hw.host.win)
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
			history_status(hw, "")
			app_announce(app, .Good, i18n.tr("Uploaded: the address is on the clipboard"), v.url, history_window_of(app))
		} else {
			history_status(hw, "")
			app_announce(app, .Bad, i18n.tr("Not uploaded"), v.problem, history_window_of(app))
		}
	}
}

@(private = "file")
history_pixels :: proc(app: ^App, v: History_Pixels) {
	hw := &app.history_window
	switch v.purpose {
	case .Copy:
		if !v.ok { app_announce(app, .Bad, i18n.tr("The picture cannot be read"), "", history_window_of(app)); return }
		if platform.clipboard_set_image(app.anchor, {rgba = v.rgba, size = v.size, png = v.png}) {
			app_announce(app, .Good, i18n.tr("Copied to the clipboard"), "", history_window_of(app))
		} else {
			app_announce(app, .Bad, i18n.tr("The picture cannot go to the clipboard"), "", history_window_of(app))
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
	// (what was asked in the window goes with it; the preview, a pane, stays for its next show)
	vs := &app.views
	ui.palette_close(&hw.palette)
	ui.shortcuts_sheet_close(&hw.sheet)
	ui.palette_close(&hw.workflow_mode.add)
	ui.view_close(vs, HISTORY_DELETE_VIEW)
	clear(&hw.delete_ids)
	ui.view_close(vs, WORKFLOW_DELETE_VIEW)
	ui.menu_close()
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
	setup.logo_destroy(&app.shared.r, &app.install.vendor_mark)
	delete(hw.thumbs)
	ui.palette_destroy(&hw.palette)   // (its usage memory written)
	// (the screenshots open the window again after this: its sources are added to the next palette)
	hw.captures, hw.workflows_source, hw.palette_settings = {}, {}, {}
	hw.palette_version = 0
	ui.shortcuts_sheet_destroy(&hw.sheet)
	command_table_destroy(&hw.sheet_table)
	hw.sheet_language = 0
	settings_mode_free(app)
	workflow_mode_free(app)
	ui.line_edit_destroy(&hw.search)
	ui.table_destroy(&hw.table)
	ui.table_data_destroy(&hw.table_data)
	ui.vlist_destroy(&hw.grid)   // (the selection is the table's: table_destroy frees it)
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
	if ui.theme_show(&app.shared.theme, app.themes_file.all[:], choice, &hw.theme_shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !hw.theme_shown.light)
	}
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
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
	// (the user's own themes: read again when their file changed; every window shows the new list at its next frame)
	if prefs_page.themes_file_poll(&app.themes_file, &hw.host.state) { hw.host.settle = max(hw.host.settle, 2) }
	if hw.mode_built != app.settings.history_view {
		// (the selection is the same; the cursor goes to its entry in the other view's rows, brought into view)
		hw.cursor_id, hw.cursor_due = history_cursor(app), true
		hw.mode_built = app.settings.history_view
		hw.table_due = true
		history_reveal(hw)
	}
	// (the grid's rows are the entries shown, fresh now; the list's are its table's, fresh once it is applied)
	if hw.mode_built == .Grid { history_rows_settle(app) }

	// (asked outside a build, cliche --setup: the setup's view opens in this window, in its build)
	if hw.setup_due {
		hw.setup_due = false
		prefs_page.install_open(&app.install)
	}
	// (the preview closed by its own close, its menu or the palette: its picture goes)
	if !ui.view_is_open(&app.views, PREVIEW_VIEW) && (hw.preview_id != 0 || hw.preview_asked != 0) { history_preview_drop(app) }

	workflows := hw.workflow_mode.open
	settings := hw.settings_mode.open
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###history") {   // (the theme's surface: the host only clears to black)
		// (cliche's title bar across the whole window, over the views docked at its edges)
		window_title_bar(h, APP_TITLE, em)
		// (the views docked at the window's edges, and the floating ones, are built first: their keys are theirs first)
		if ui.views_frame(&app.views) {
			dialog := history_views_open(app) || ui.menu_any_open()
			// (the window's own commands first, in every mode, whatever has the keyboard, over the window's views too (a
			// question, the sheet, the palette); not while a menu is open: its keys, Escape and the letters that search
			// it, are its own until it closes)
			// (the palette's sources given what they list now, then its keys: Ctrl+K and Ctrl+Shift+P are the toolkit's)
			history_palette_feed(app)
			if !ui.menu_any_open() {
				ui.palette_keys(&hw.palette)
				history_window_keys(app)
			}
			if !dialog && workflows {
				workflow_keys(app)
			} else if !dialog && settings {
				settings_keys(app)
			} else if !dialog {
				// (the toolkit's rule first: several entries selected, the cursor's alone; then the search's, then the window's)
				if ui.key_press(.Escape) {
					switch {
					case ui.item_selection_escape(history_selection(hw), history_rows(app)):
					case hw.search_focused && len(hw.search.buf) > 0: ui.line_edit_set(&hw.search, ""); hw.shown_due = true
					case: hw.hide_due = true
					}
				}
				history_keys(app, .History, false)
				ui.type_to_field(hw.search_key)
			}
			switch {
			case workflows: workflow_build(app, em)
			case settings:  settings_build(app, em)
			case:           history_page(app, em)
			}
		}
	}
	if !settings && !workflows { history_menu(app, em) }
	history_dialogs(app)
	if prefs_page.install_frame(&app.install) == .Launched { app.quit = true }   // (the installed copy starts at the end: app_run)
}

// Whether a view of the window that takes the keys is open, wherever the user put it: its palettes, its sheet, a
// question, the setup. The window's own keys wait for it, as they waited for its dialogs. The preview is not one: it
// leaves the keys to the page.
@(private = "file")
history_views_open :: proc(app: ^App) -> bool {
	hw := &app.history_window
	vs := &app.views
	return ui.palette_is_open(&hw.palette) || ui.shortcuts_sheet_is_open(&hw.sheet) || ui.palette_is_open(&hw.workflow_mode.add) ||
		ui.view_is_open(vs, HISTORY_DELETE_VIEW) || ui.view_is_open(vs, WORKFLOW_DELETE_VIEW) || prefs_page.install_open_now(&app.install)
}

// The history's mode: the toolbar, the grid or the list in the dock space of the preview, the footer.
@(private = "file")
history_page :: proc(app: ^App, em: f32) {
	history_toolbar(app, em)
	ui.hline(ui.fill())
	crash_bar.bar(&app.crash_bar, {name = APP_TITLE, version = APP_VERSION, repository = "sachahjkl/cliche"})
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.views_dock(&app.views, HISTORY_SPACE, {content = true}) {
		history_main(app, em)
	}
	history_footer(app, em)
}

// Once, at the start: the history window's own view, the preview, a panel at the right of the grid or the list.
history_views_register :: proc(app: ^App) {
	ui.view_register(&app.views, PREVIEW_VIEW, history_preview_view, ui.View_Options{
		title = i18n.later("Preview"), icon = lucide.EYE, home = .Panel, home_place = {space = HISTORY_SPACE, edge = .Right},
		extent_em = HISTORY_PREVIEW_EM, width_em = HISTORY_PREVIEW_EM, min_width_em = HISTORY_PREVIEW_MIN_EM,
	})
}

// The palette's button at the right end of a mode's bar (the settings', the workflows'), as in the history's toolbar.
history_palette_button :: proc(app: ^App, em: f32) {
	if history_icon_button("palette", lucide.COMMAND, ui.command_tip(ui.palette_command()), em) { history_palette_show(app) }
	ui.spacer(ui.px(em * 0.6))
}

// What the window's palette lists, given to its sources: at the top of each build, before its keys open it. The commands
// source compares a version only, raised when what can act changes: two sets compared, the history's kept by
// history_enabled on the selection's version (no pass over the table nor over the selection). The settings source is
// added once: it reads its page options when it reads (settings_options).
history_palette_feed :: proc(app: ^App) {
	hw := &app.history_window
	if hw.palette_commands[0].label == "" {
		copy(hw.palette_commands[:], slice.enumerated_array(&HISTORY_ACTIONS))
		copy(hw.palette_commands[len(History_Action):], slice.enumerated_array(&SETTINGS_ACTIONS))
		copy(hw.palette_commands[len(History_Action) + len(Settings_Action):], slice.enumerated_array(&WORKFLOW_ACTIONS))
	}
	can := History_Palette_Can{actions = history_enabled(app)}
	for a in Settings_Action { if settings_action_enabled(app, a) { can.settings += {a} } }
	if can != hw.palette_can || hw.palette_version == 0 {
		hw.palette_can = can
		hw.palette_version += 1
		for a in History_Action { hw.palette_disabled[int(a)] = a not_in can.actions }
		for a in Settings_Action { hw.palette_disabled[len(History_Action) + int(a)] = a not_in can.settings }
	}
	// (the Workflows mode's commands while it is shown: the table's length is part of what the palette compares)
	n := hw.workflow_mode.open ? HISTORY_PALETTE_COUNT : len(History_Action) + len(Settings_Action)
	ui.palette_commands(&hw.palette, hw.palette_commands[:n], hw.palette_disabled[:n], {version = hw.palette_version})
	if !ui.palette_has(&hw.palette, &hw.captures) {
		hw.captures = captures_source(app)
		ui.palette_add(&hw.palette, &hw.captures)
	}
	if !ui.palette_has(&hw.palette, &hw.workflows_source) {
		hw.workflows_source = workflows_source(app)
		ui.palette_add(&hw.palette, &hw.workflows_source)
	}
	if !ui.palette_has(&hw.palette, &hw.palette_settings.source) {
		prefs_page.palette_settings_add(&hw.palette, &hw.palette_settings, &app.prefs, &hw.settings_mode.page,
			proc(user: rawptr) -> prefs_page.Page_Options { return settings_options((^App)(user)) },
			proc(user: rawptr) { settings_enter((^App)(user)) }, app)
	}
}

// The history's palette (the toolbar's button, the screenshots): opened, or closed when it is open.
history_palette_show :: proc(app: ^App) {
	history_palette_feed(app)
	ui.palette_toggle(&app.history_window.palette)
}

// The palette's choice of cliche's own sources: a command of the window (the history's, the settings', the workflows'),
// a capture (shown selected in the history), a workflow (shown in the Workflows mode). The settings and the views' moves
// act in palette_chosen itself.
@(private = "file")
history_palette_chosen :: proc(app: ^App) {
	hw := &app.history_window
	c, ok := ui.palette_chosen(&hw.palette)
	if !ok { return }
	if i, is := ui.palette_chosen_command(&hw.palette, c); is {
		settings_at := len(History_Action)
		flows_at := settings_at + len(Settings_Action)
		switch {
		case i < settings_at: history_action(app, History_Action(i))
		case i < flows_at:    settings_action(app, Settings_Action(i - settings_at))
		case:                 workflow_action(app, Workflow_Action(i - flows_at))
		}
		return
	}
	if c.source == &hw.captures {
		history_go_to(app, palette_id_number(c.id))
	} else if c.source == &hw.workflows_source {
		id := palette_id_number(c.id)
		workflows_show(app)
		workflow_show(app, id)
	}
}

// A capture chosen in the palette: the history shown, the search and the filters cleared (it may be hidden by them), the
// entry selected alone and brought into view.
@(private = "file")
history_go_to :: proc(app: ^App, id: u64) {
	hw := &app.history_window
	if history_find(&hw.history, id) == nil { return }   // (removed since)
	settings_leave(app)
	workflow_mode_leave(app)
	ui.line_edit_set(&hw.search, "")
	hw.filter, hw.period = .All, .Any
	hw.shown_due = true
	hw.select_due = id
}

// The entries shown, made again when the history, the search, the filter or the sort changed (not per frame).
@(private = "file")
history_refresh :: proc(app: ^App) {
	hw := &app.history_window
	query := strings.trim_space(ui.line_edit_string(&hw.search))
	if query != hw.query { hw.shown_due = true }
	if !hw.shown_due && hw.shown_version == hw.history.version { return }
	// (the cursor is an index: its entry, taken before the rows change, finds its place in the new ones)
	if !hw.cursor_due { hw.cursor_id, hw.cursor_due = history_cursor(app), true }
	delete(hw.query)
	hw.query = strings.clone(query)
	delete(hw.shown)
	since := history_period_start(hw.period, i64(time.to_unix_nanoseconds(time.now()) / 1_000_000), hw.offset_minutes)
	hw.shown = history_shown(&hw.history, hw.query, hw.filter, hw.sort, hw.descending, since_ms = since)
	resize(&hw.shown_ids, len(hw.shown))
	for p, i in hw.shown { hw.shown_ids[i] = hw.history.entries[p].id }
	hw.shown_version = hw.history.version
	hw.shown_due = false
	hw.table_due = true
	hw.grid_columns = 0   // (the grid's lines are made again)
	hw.rows_due = true
}

// The window's selection, the grid's and the list's: the list's table's (its List_State's).
history_selection :: proc(hw: ^History_Window) -> ^ui.Item_Selection { return &hw.table.vl.selection }

// The rows the selection is over, in the view built: the list's table's ids (its order), else the entries shown.
history_rows :: proc(app: ^App) -> ui.Item_Rows {
	hw := &app.history_window
	if hw.mode_built == .List && len(hw.table.ids) == len(hw.shown_ids) { return {count = len(hw.table.ids), ids = hw.table.ids[:]} }
	return {count = len(hw.shown_ids), ids = hw.shown_ids[:]}
}

// The entry of the cursor (0: none): what the acts on one picture take (preview, edit, pin, copy the picture).
history_cursor :: proc(app: ^App) -> u64 {
	sel := history_selection(&app.history_window)
	rows := history_rows(app)
	return sel.sel >= 0 && sel.sel < rows.count ? ui.item_rows_id(rows, sel.sel) : 0
}

// The rows are fresh (the entries shown made again, the table applied, the other view's): the entries gone leave the
// selection, the cursor goes back to its entry, an entry asked for is selected alone. Only when one of them is due.
history_rows_settle :: proc(app: ^App) {
	hw := &app.history_window
	if !hw.rows_due && !hw.cursor_due && hw.select_due == 0 { return }
	sel := history_selection(hw)
	rows := history_rows(app)
	if hw.rows_due {
		ui.item_selection_keep(sel, rows)
		hw.rows_due = false
	}
	if hw.cursor_due {
		hw.cursor_due = false
		sel.sel = hw.cursor_id != 0 ? ui.item_rows_find(rows, hw.cursor_id) : -1
	}
	if hw.select_due != 0 {
		if at := ui.item_rows_find(rows, hw.select_due); at >= 0 {
			ui.item_selection_one(sel, rows, at)
			history_reveal(hw)
		}
		hw.select_due = 0
	}
	sel.version += 1   // (what is made from the selection is made again: the acts that can act, the preview)
}

// The cursor brought into view at the next build, in the grid and in the list.
history_reveal :: proc(hw: ^History_Window) {
	hw.grid_reveal = true
	hw.table.vl.reveal = HISTORY_REVEAL_FRAMES
}

// Frames the list keeps scrolling its cursor's row into view.
HISTORY_REVEAL_FRAMES :: 3

@(private = "file")
history_toolbar :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	field_h := ui.px(math.round(em * 1.9))
	filters: [History_Filter]string
	for text, f in HISTORY_FILTER_TEXT { filters[f] = i18n.tr(text) }
	sizes := [3]string{i18n.tr("thumbnail size, short", "S"), i18n.tr("thumbnail size, short", "M"), i18n.tr("thumbnail size, short", "L")}
	views := [2]string{i18n.tr("Grid"), i18n.tr("List")}
	// (each segmented control is as wide as its words need, ui.segmented's own width: the layout reads it first; the
	// buttons and the toolkit's room between a bar's items and groups, roughly)
	segments_w := ui.segmented_width(slice.enumerated_array(&filters)) + ui.segmented_width(sizes[:]) + ui.segmented_width(views[:])
	tools_w := segments_w + em * (6 * 2.2 + 5 * 0.2 + 3 * 0.8 + 3 * 1.0)
	placeholder := i18n.tr("Search names, texts, URLs")
	search_min := max(em * HISTORY_SEARCH_MIN_EM, ui.text_width(ui.top_style().font, em, placeholder) + em * 2.5)
	// (the search beside the tools while its placeholder fits, as the last layout measured the window; else the tools go
	// to a line of their own under it, a tool bar that folds what does not fit into its "…" menu)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###toolbar_lines") {
		r := ui.parent_box().rect
		width := r.max.x - r.min.x
		stacked := width > 0 && width - tools_w - em * 0.6 < search_min
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.9)), axis = .X, cross = .Center})
		if ui.row(id = "###toolbar") {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = field_h})
			s := ui.line_edit("###search", &hw.search, {placeholder = placeholder, clearable = true})
			if s.box != nil { hw.search_key = s.box.key }
			hw.search_focused = s.focused
			if s.changed { hw.shown_due = true }
			if s.committed { hw.grid_reveal = true }
			ui.spacer(ui.px(em * 0.6))
			// (beside the search: as wide as its items, at most what the search leaves; never past the window's edge: a
			// tool that does not fit folds into its "…" menu)
			if !stacked {
				room := max(width - search_min - em * 1.8, em * 3)
				history_tools(app, slice.enumerated_array(&filters), sizes[:], views[:], ui.px(math.round(min(tools_w, room))), em)
			}
		}
		if stacked {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.6)), axis = .X, cross = .Center})
			if ui.row(id = "###toolbar_tools") {
				ui.spacer(ui.px(em * 0.6))
				history_tools(app, slice.enumerated_array(&filters), sizes[:], views[:], ui.fill(), em)
				ui.spacer(ui.px(em * 0.6))
			}
		}
	}
}

// The search keeps at least this, in ems, beside the tools (and its placeholder's width).
HISTORY_SEARCH_MIN_EM :: 16

// The toolbar's choices and buttons, after the search (in its row, or in a row of their own when the window is narrow):
// the toolkit's tool bar, folding what does not fit into its "…" menu (a choice there is a row with its label and its
// segmented control; a button a row). The least needed fold first: the open folder, the thumbnails' size, the view, the
// window's buttons; the filter by kind last. `width`: the bar's.
@(private = "file")
history_tools :: proc(app: ^App, filters, sizes, views: []string, width: ui.Size, em: f32) {
	field_h := ui.px(math.round(em * 1.9))
	ui.next({width = width, height = ui.px(math.round(em * 2.2))})
	if ui.toolbar("history_tools", {overflow = .Fold}) { history_tools_groups(app, filters, sizes, views, field_h) }
}

// The groups of the history's tool bar, in its order (inside ui.toolbar's block: its end closes it).
@(private = "file")
history_tools_groups :: proc(app: ^App, filters, sizes, views: []string, field_h: ui.Size) {
	hw := &app.history_window
	if ui.toolbar_group("kind", {title = i18n.tr("Kind"), priority = 4}) {
		if ui.toolbar_control("filter", {label = i18n.tr("Kind")}) {
			chosen := int(hw.filter)
			ui.next({height = field_h})
			if ui.segmented("filter", filters, &chosen) {
				hw.filter = History_Filter(chosen)
				hw.shown_due = true
			}
		}
	}
	if ui.toolbar_group("size", {title = i18n.tr("Thumbnail size"), priority = 1}) {
		if ui.toolbar_control("thumb_size", {label = i18n.tr("Thumbnail size")}) {
			tips := [3]string{i18n.tr("Small thumbnails"), i18n.tr("Medium thumbnails"), i18n.tr("Large thumbnails")}
			step := app.settings.history_thumbnail
			ui.next({height = field_h})
			if ui.segmented("thumb_size", sizes, &step, tips[:]) { history_pref(app, "history.thumbnail_size", HISTORY_THUMBNAIL_NAMES[clamp(step, 0, 2)]) }
		}
	}
	if ui.toolbar_group("view", {title = i18n.tr("View"), priority = 2}) {
		if ui.toolbar_control("view", {label = i18n.tr("View")}) {
			view := int(app.settings.history_view)
			ui.next({height = field_h})
			if ui.segmented("view", views, &view) {
				if view == 0 { history_action(app, .Grid) } else { history_action(app, .List) }
			}
		}
	}
	if ui.toolbar_group("window", {title = i18n.tr("Window"), priority = 3}) {
		// (the date's filter in a menu: four choices would make the bar too wide; the tip says the one in use)
		ui.toolbar_tool("period", {label = i18n.tr("Show by date…"), icon = lucide.CALENDAR, menu = HISTORY_PERIOD_MENU_ID, menu_search = false,
			tip = fmt.tprintf("%s: %s", i18n.tr("Date"), i18n.tr(HISTORY_PERIOD_TEXT[hw.period]))})
		// (the keys in the tooltips as the keyboards of the language name them)
		preview := ui.view_is_open(&app.views, PREVIEW_VIEW)
		if ui.toolbar_tool("preview", {label = i18n.tr("Preview"), icon = lucide.EYE, shortcut = ui.command_shortcut(HISTORY_ACTIONS[.Preview]), on = preview,
			tip = ui.key_tip(preview ? i18n.tr("Hide the preview") : i18n.tr("Preview"), {.Space, {}})}) { history_action(app, .Preview) }
		if ui.toolbar_tool("folder", {label = i18n.tr("Open the save folder"), icon = lucide.FOLDER_OPEN, priority = 0}) { history_action(app, .Open_Folder) }
		if ui.toolbar_tool("workflows", {label = i18n.tr("Workflows"), icon = lucide.GIT_FORK, shortcut = ui.command_shortcut(HISTORY_ACTIONS[.Workflows]),
			tip = ui.key_tip(i18n.tr("Workflows: what happens after a capture"), {.W, {.Ctrl, .Shift}})}) { history_action(app, .Workflows) }
		if ui.toolbar_tool("palette", {command = ui.palette_command()}) { history_palette_show(app) }
		if ui.toolbar_tool("settings", {label = i18n.tr("Settings"), icon = lucide.SETTINGS, shortcut = ui.command_shortcut(HISTORY_ACTIONS[.Settings])}) { history_action(app, .Settings) }
	}
}

@(private = "file")
history_icon_button :: proc(id, glyph, tip: string, em: f32) -> bool {
	ui.next({width = ui.px(math.round(em * 2.1)), height = ui.px(math.round(em * 2.1)), font_size = em * 1.15})
	return ui.button(id, icon = glyph, o = {tip = tip}).clicked
}

// The grid, the list, or what stands for them with nothing to show.
@(private = "file")
history_main :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	if len(hw.history.entries) == 0 {
		keys := shortcut_keys(app, .Region)
		note := keys != "" ? fmt.tprintf(i18n.tr("Press %s, or click Cliche's icon in the notification area: each capture comes here."), keys) : i18n.tr("Click Cliche's icon in the notification area, or run cliche --region: each capture comes here.")
		if !hw.loaded { note = i18n.tr("Reading the history…") }
		if ui.empty_state("empty", {icon = lucide.HISTORY, title = i18n.tr("No capture yet"), note = note, actions = {{text = i18n.tr("Capture a region"), icon = lucide.SCISSORS, intent = .Primary}}}) == 0 {
			history_action(app, .Capture_Region)
		}
		return
	}
	if len(hw.shown_ids) == 0 {
		if ui.empty_state("nothing", {icon = lucide.SEARCH, title = i18n.tr("Nothing matches"), note = i18n.tr("No capture has these words, or is of this kind."), actions = {{text = i18n.tr("Clear the search"), icon = lucide.X}}}) == 0 {
			ui.line_edit_set(&hw.search, "")
			hw.filter, hw.period = .All, .Any
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
		// (an update on offer, coming or in place: the one place that shows it, as in every program of the toolkit)
		if app.updates.updater != nil {
			ui.next({height = ui.px(math.round(em * 1.5))})
			if prefs_page.update_badge(app.updates.updater, proc(user: rawptr) { app_restart((^App)(user)) }, app) != nil { ui.spacer(ui.px(em * 0.6)) }
		}
		if ui.tags("weak") {
			n := len(history_selection(hw).selected)
			count := len(hw.shown_ids) == len(hw.history.entries) ? fmt.tprintf(i18n.tr(len(hw.history.entries), "%d captures", "%d captures"), len(hw.history.entries)) : fmt.tprintf(i18n.tr(len(hw.shown_ids), "%d of %d captures", "%d of %d captures"), len(hw.shown_ids), len(hw.history.entries))
			if n > 1 { count = fmt.tprintf(i18n.tr("%s, %d selected"), count, n) }
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###count", count))
			ui.spacer(ui.px(em * 1.2))
			// (content: a message, a link uploaded or an error said there, to copy)
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, flags = {.Selectable}})
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
		if at := history_selection(hw).sel; at >= 0 && at < len(hw.shown_ids) { ui.list_select(&hw.grid, at / columns) }
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
	sel := history_selection(hw)
	rows := history_rows(app)
	selected := ui.item_selection_has(sel, rows, i)
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
			ui.label(fmt.tprintf("%s###when", e.missing ? i18n.tr("File missing") : history_time_text(hw, e.time_ms)))
		}
	}
	// (the toolkit's rules: alone, Ctrl toggles, Shift the range from the anchor, Ctrl+Shift the range added)
	if sig.pressed { ui.item_selection_click(sel, rows, i, sig.mods) }
	if sig.double_clicked { history_action(app, .Open) }
	if sig.right_clicked {
		// (outside the selection: the cell alone; on it: the selection stays, the menu acts on it)
		ui.item_selection_context(sel, rows, i)
		ui.menu_open(HISTORY_MENU_ID, ui.mouse_pos())
	}
}

@(private = "file")
history_cell_picture :: proc(app: ^App, e: History_Entry, cell, em: f32) {
	hw := &app.history_window
	if e.kind == .Qr || e.kind == .Text {
		ui.next({width = ui.px(cell), height = ui.px(cell), radius = em * 0.3, font_size = math.round(em * 0.85), text_pad = em * 0.5})
		if ui.tags("weak") {
			// (content: a press picks the cell and a double click opens it, as before; a drag selects the words)
			ui.build_box({.Draw_Text, .Text_Wrap, .Clip, .Selectable}, fmt.tprintf("%s###text", ui.text_shown(history_first_words(e.text, 160))))
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
	if e.missing || e.kind == .File { glyph = lucide.FILE }
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
	picture := history_kind_picture(e.kind)
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
	// (the thumbnails' size of the grid is the list's too: rows as high, the lead as wide as a thumbnail)
	t.row_em = HISTORY_ROW_EM[clamp(app.settings.history_thumbnail, 0, 2)]
	t.lead_em = (t.row_em - 0.5) * HISTORY_ROW_THUMB_ASPECT + 0.4
	if hw.table_due {
		hw.table_due = false
		ui.table_data_reset(&hw.table_data, len(History_Column))
		for p in hw.shown {
			e := hw.history.entries[p]
			name := history_name(e)
			ui.table_data_row(&hw.table_data, e.id, name, e.missing ? .Dim : .Normal)
			ui.table_data_cell(&hw.table_data, e.missing ? fmt.tprintf(i18n.tr("%s (missing)"), name) : name)
			ui.table_data_cell(&hw.table_data, history_kind_text(e.kind))
			ui.table_data_cell(&hw.table_data, history_size_text(e), f64(e.bytes) + f64(e.size.x * e.size.y) * 1e-9)
			ui.table_data_cell(&hw.table_data, history_time_text(hw, e.time_ms), f64(e.time_ms))
			ui.table_data_cell(&hw.table_data, e.url)
		}
		// (filtered already: the table's own filter is given nothing, its highlight is the search)
		ui.table_apply(t, &hw.table_data, "")
		t.highlight = hw.query
	}
	// (the table's ids are fresh: the list's rows; its selection is the window's, the grid's too)
	history_rows_settle(app)
	dialog := history_views_open(app) || ui.menu_any_open()
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
	if ev.activated || keys.activated { history_action(app, .Open) }
	if ev.menu || keys.menu {
		at := ev.menu ? ev.menu_at : keys.menu_at
		ui.menu_open(HISTORY_MENU_ID, at, from_keyboard = ev.keyboard || keys.keyboard)
	}
}

// The kind's icon before a row's name.
@(private = "file")
history_table_lead :: proc(t: ^ui.Table, row: int, size: f32) {
	app := (^App)(t.lead_user)
	hw := &app.history_window
	if row < 0 || row >= len(hw.shown) { return }
	e := hw.history.entries[hw.shown[row]]
	box := [2]f32{math.round(size * HISTORY_ROW_THUMB_ASPECT), math.round(size)}
	if e.kind != .Qr && e.kind != .Text {
		if th := history_thumb(app, e); th != nil && th.state == .Ready {
			d := ui.frame_new(History_Thumb_Draw)
			d^ = {tex = th.tex, size = {f32(th.size.x), f32(th.size.y)}, radius = size * 0.08, dim = e.missing}
			ui.next({width = ui.px(box.x), height = ui.px(box.y)})
			ui.custom("###thumb", history_thumb_draw, d)
			return
		}
	}
	glyph := lucide.IMAGE
	switch e.kind {
	case .Region, .Screen, .Window, .Picture: glyph = lucide.IMAGE
	case .Video, .Gif:                        glyph = lucide.FILM
	case .Qr:                                 glyph = lucide.QR_CODE
	case .Text:                               glyph = lucide.FILE_TEXT
	case .File:                               glyph = lucide.FILE
	}
	if e.missing { glyph = lucide.FILE }
	// (no thumbnail, or not yet: the kind's icon where it will be, so the text does not move when it comes)
	ui.next({width = ui.px(box.x), height = ui.px(box.y), font = hw.icons, font_size = math.round(min(size * 0.6, ui.font_size() * 1.5)), text_align = .Center, fg = e.missing ? ui.color("weak text") : nil})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###thumb", glyph))
}

////////////////////////////////
// The preview

// The view PREVIEW_VIEW: the capture selected, as large as its place, and what it is under it. Its place is the
// toolkit's (a panel beside the grid, a floating window, a window of its own): it fills it.
@(private = "file")
history_preview_view :: proc(v: ^ui.View, app: ^App) {
	hw := &app.history_window
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###preview_pane") {
		e := history_find(&hw.history, history_cursor(app))
		if e == nil {
			ui.empty_state("no_preview", {icon = lucide.EYE, title = i18n.tr("Nothing selected"), note = i18n.tr("Select a capture to see it here.")})
			return
		}
		picture := history_kind_picture(e.kind)
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
				ui.empty_state("loading", {icon = lucide.LOADER, title = i18n.tr("Reading the picture…")})
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
				ui.empty_state("no_picture", {icon = e.missing ? lucide.FILE : lucide.FILM, title = e.missing ? i18n.tr("The file is missing") : i18n.tr("No picture"), note = e.missing ? e.path : ""})
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
	append(&lines, fmt.tprintf("%s, %s", history_kind_text(e.kind), history_time_text(hw, e.time_ms)))
	if s := history_size_text(e); s != "" { append(&lines, s) }
	if e.path != "" { append(&lines, e.missing ? fmt.tprintf(i18n.tr("%s (missing)"), e.path) : e.path) }
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

// The keys of the window's own commands (scope .Window), in every mode: the toolkit takes them whatever has the focus.
@(private = "file")
history_window_keys :: proc(app: ^App) {
	enabled := history_enabled(app)
	for a in History_Action {
		if HISTORY_ACTIONS[a].scope != .Window { continue }
		if ui.command_pressed(HISTORY_ACTIONS[a], a not_in enabled) { history_action(app, a); return }
	}
}

@(private = "file")
history_keys :: proc(app: ^App, mode: History_Mode, typing: bool) {
	hw := &app.history_window
	enabled := history_enabled(app)
	read := history_keys_read(mode, typing)
	for a in History_Action {
		if a not_in read { continue }
		if mode == .History && hw.search_focused && a in HISTORY_FIELD_KEYS { continue }
		if ui.command_pressed(HISTORY_ACTIONS[a], a not_in enabled) { history_action(app, a); return }
	}
	// (the grid's moves are the history's alone: the arrows are the settings' and the graph's elsewhere)
	if mode != .History || app.settings.history_view != .Grid || len(hw.shown_ids) == 0 { return }
	// the grid's moves: the key gives the cell the cursor goes to (a line is `grid_columns` cells), the toolkit's model
	// what its modifiers do (alone: the cell alone; Shift: the range from the anchor; Ctrl+Shift: the range added; Ctrl:
	// the cursor alone moves). The search keeps Left, Right, Home and End while it has the keyboard.
	sel := history_selection(hw)
	rows := history_rows(app)
	if ui.key_press(.Space, {.Ctrl}) && sel.sel >= 0 {
		ui.item_selection_toggle(sel, rows, sel.sel)
		return
	}
	columns := max(hw.grid_columns, 1)
	page := columns * max(hw.grid.page_rows - 1, 1)
	@(static, rodata) all_mods := [4]platform.Modifiers{{}, {.Shift}, {.Ctrl}, {.Ctrl, .Shift}}
	@(static, rodata) keys := [8]platform.Key{.Left, .Right, .Home, .End, .Up, .Down, .Page_Up, .Page_Down}
	for mods in all_mods {
		for k in keys {
			if hw.search_focused && (k == .Left || k == .Right || k == .Home || k == .End) { continue }
			if !ui.key_press(k, mods) { continue }
			to := history_grid_target(sel.sel, rows.count, columns, page, k)
			ui.item_selection_move(sel, rows, to, mods)
			history_reveal(hw)
			return
		}
	}
}

// The cell a key of the grid takes the cursor to: Left and Right a cell, Up and Down a line of `columns`, Page Up and
// Page Down `page` cells, Home and End the ends; clamped to the `count` cells. With no cursor, the first cell.
history_grid_target :: proc(at, count, columns, page: int, key: platform.Key) -> int {
	if count <= 0 { return -1 }
	if at < 0 || at >= count { return 0 }
	to := at
	#partial switch key {
	case .Left:      to = at - 1
	case .Right:     to = at + 1
	case .Up:        to = at - columns
	case .Down:      to = at + columns
	case .Page_Up:   to = at - page
	case .Page_Down: to = at + page
	case .Home:      to = 0
	case .End:       to = count - 1
	}
	return clamp(to, 0, count - 1)
}

@(private = "file")
history_menu :: proc(app: ^App, em: f32) {
	hw := &app.history_window
	if ui.menu(HISTORY_MENU_ID, em * 17) {
		enabled := history_enabled(app)
		for a in HISTORY_MENU {
			if a in HISTORY_MENU_BREAKS { ui.menu_separator() }
			c := HISTORY_ACTIONS[a]
			if ui.menu_item(i18n.tr(c.label), ui.command_shortcut(c), false, c.icon, a not_in enabled, icon_font = hw.icons).clicked { history_action(app, a) }
		}
	}
	if ui.menu(HISTORY_PERIOD_MENU_ID, em * 13) {
		for text, p in HISTORY_PERIOD_TEXT {
			if ui.menu_item(i18n.tr(text), "", p == hw.period, "", false, icon_font = hw.icons).clicked && p != hw.period {
				hw.period = p
				hw.shown_due = true
			}
		}
	}
}

// The sheet's table: every action of the window, from constant tables; made once, and again in another language. True:
// it was made again.
@(private = "file")
history_sheet_keep :: proc(app: ^App) -> bool {
	hw := &app.history_window
	if hw.sheet_table.version != 0 && hw.sheet_language == i18n.version() { return false }
	hw.sheet_language = i18n.version()
	a := command_table_remake(&hw.sheet_table)
	hw.sheet_table.commands = slice.concatenate([][]ui.Command{slice.enumerated_array(&HISTORY_ACTIONS), slice.enumerated_array(&SETTINGS_ACTIONS), slice.enumerated_array(&WORKFLOW_ACTIONS)}, a)
	return true
}

// The answers of the window's views: the palette's choice, the question before files are deleted; and the sheet's table
// kept while it is open.
@(private = "file")
history_dialogs :: proc(app: ^App) {
	hw := &app.history_window
	history_palette_chosen(app)
	// (an open sheet lists from the table, which the making empties: it gets the new one at once)
	if ui.shortcuts_sheet_is_open(&hw.sheet) && history_sheet_keep(app) {
		hw.sheet.commands, hw.sheet.version = hw.sheet_table.commands, hw.sheet_table.version
	}
	switch ui.confirm_answer(HISTORY_DELETE_VIEW) {
	case .Confirmed:
		// (the question may have floated beside the history while it changed: what is still there goes)
		ids := make([dynamic]u64, 0, len(hw.delete_ids), context.temp_allocator)
		for id in hw.delete_ids {
			if e := history_find(&hw.history, id); e != nil && e.path != "" && !e.missing { append(&ids, id) }
		}
		clear(&hw.delete_ids)
		if len(ids) == 0 { return }
		worker_send(&app.worker, Job_History(History_Delete{ids = clone_ids(ids[:])}))
		app_announce(app, .Good, len(ids) == 1 ? i18n.tr("The file is deleted") : fmt.tprintf(i18n.tr("%d files are deleted"), len(ids)), "", history_window_of(app))
	case .Cancelled:
		clear(&hw.delete_ids)
	case .None:
	}
}

// The question before the files of `ids` are deleted for good (those with a file on the disk).
@(private = "file")
history_delete_ask :: proc(app: ^App, ids: []u64) {
	hw := &app.history_window
	clear(&hw.delete_ids)
	names := make([dynamic]string, context.temp_allocator)
	for id in ids {
		if e := history_find(&hw.history, id); e != nil && e.path != "" && !e.missing {
			append(&hw.delete_ids, id)
			append(&names, e.path)
		}
	}
	if len(names) == 0 { return }
	title := fmt.tprintf(i18n.tr("Delete %d files for good?"), len(names))
	if len(names) == 1 { title = fmt.tprintf(i18n.tr("Delete %s for good?"), names[0][strings.last_index_any(names[0], "/\\") + 1:]) }
	ui.confirm_open(HISTORY_DELETE_VIEW, {title = title, note = i18n.tr("The files go from the disk, not to the trash. Their lines stay in the history, marked missing."), lines = names[:], act = i18n.tr("Delete")})
}

// The entries the acts on entries take (open, copy the paths, upload, combine, delete, remove...): every one selected, in
// the order shown; with none selected, the cursor's (temp memory).
history_selected :: proc(app: ^App) -> []u64 {
	hw := &app.history_window
	ids := ui.item_selection_ids(history_selection(hw), history_rows(app))
	if len(ids) == 0 {
		if cursor := history_cursor(app); cursor != 0 {
			one := make([]u64, 1, context.temp_allocator)
			one[0] = cursor
			return one
		}
	}
	return ids
}

// The actions that can act now. Made again only when the entries, the selection or the view changed: it passes over
// the selection, which Ctrl+A makes as large as the history.
history_enabled :: proc(app: ^App) -> History_Actions {
	hw := &app.history_window
	settings := hw.settings_mode.open || hw.workflow_mode.open
	sel := history_selection(hw)
	// (the cursor too: Ctrl+arrows move it alone, and the acts on one picture follow it)
	stamp := [4]u64{hw.history.version, sel.version, u64(app.settings.history_view) + u64(len(hw.shown_ids)) << 8 + u64(settings) << 62, u64(sel.sel + 1)}
	if stamp == hw.enabled_stamp && hw.enabled_made { return hw.enabled }
	hw.enabled_stamp, hw.enabled_made = stamp, true
	// (on the settings: what concerns the window alone; the history's actions wait for it)
	window := History_Actions{.Open_Folder, .Capture_Region, .Workflows, .Settings, .Keys, .Close, .Quit}
	if settings {
		hw.enabled = window
		return window
	}
	out := window + {.Preview, .Search, .Period}
	if app.settings.history_view == .Grid { out += {.List} } else { out += {.Grid} }
	if len(hw.shown_ids) > 0 { out += {.Select_All} }
	acted := history_selected(app)
	if len(acted) > 0 { out += {.Remove} }
	pictures := 0
	for id in acted {
		e := history_find(&hw.history, id)
		if e == nil { continue }
		if e.path != "" { out += {.Copy_Path} }
		// (any file goes up again as it is: the host's answer, not cliche, says whether it takes it)
		if e.path != "" && !e.missing { out += {.Open, .Reveal, .Delete_File, .Upload} }
		if e.url != "" { out += {.Copy_Url, .Open_Url} }
		if e.text != "" { out += {.Copy_Text} }
		if history_is_picture(e^) && !e.missing { pictures += 1 }
	}
	if pictures >= 2 { out += {.Combine_Side, .Combine_Stack} }
	// (one picture: the cursor's)
	if e := history_find(&hw.history, history_cursor(app)); e != nil && history_is_picture(e^) && !e.missing { out += {.Copy_Picture, .Edit, .Pin} }
	hw.enabled = out
	return out
}

@(private = "file")
history_is_picture :: proc(e: History_Entry) -> bool {
	return e.path != "" && history_kind_picture(e.kind)
}

@(private = "file")
history_action :: proc(app: ^App, a: History_Action) {
	hw := &app.history_window
	if a not_in history_enabled(app) { return }
	ids := history_selected(app)
	focus := history_find(&hw.history, history_cursor(app))
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
				ui.open(e.path, .Reveal)
				break
			}
		}
	case .Copy_Picture:
		worker_send(&app.worker, Job_History(History_Picture_Ask{id = focus.id, path = strings.clone(focus.path), purpose = .Copy}))
	case .Copy_Path:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.path }, "\n", i18n.tr("The path is on the clipboard"), i18n.tr("The paths are on the clipboard"))
	case .Copy_Url:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.url }, "\n", i18n.tr("The URL is on the clipboard"), i18n.tr("The URLs are on the clipboard"))
	case .Copy_Text:
		history_copy_text(app, ids, proc(e: ^History_Entry) -> string { return e.text }, "\n\n", i18n.tr("The text is on the clipboard"), i18n.tr("The texts are on the clipboard"))
	case .Edit:
		editor_open_file(app, focus.path)
	case .Pin:
		pin_picture(app, focus.path)
	case .Open_Url:
		opened := 0
		for id in ids {
			e := history_find(&hw.history, id)
			if e == nil || e.url == "" { continue }
			ui.open(e.url, .Url)
			opened += 1
			if opened == HISTORY_OPEN_MAX { break }
		}
	case .Upload:
		for id in ids {
			e := history_find(&hw.history, id)
			if e == nil || e.path == "" || e.missing { continue }
			worker_send(&app.worker, Job_History(History_Upload{id = e.id, path = strings.clone(e.path), uploader = strings.clone(app.settings.uploader)}))
		}
		history_status(hw, i18n.tr("Uploading…"))
	case .Combine_Side, .Combine_Stack:
		// (in the order shown: the person sees which comes first)
		paths := make([dynamic]string, 0, len(ids))
		for id in ids {
			if e := history_find(&hw.history, id); e != nil && history_is_picture(e^) && !e.missing { append(&paths, strings.clone(e.path)) }
		}
		worker_send(&app.worker, Job_Combine{paths = paths[:], vertical = a == .Combine_Stack, folder = strings.clone(app.settings.folder), pattern = strings.clone(app.settings.name_pattern)})
		history_status(hw, i18n.tr("Combining the pictures…"))
	case .Period:
		ui.menu_open(HISTORY_PERIOD_MENU_ID, ui.mouse_pos())
	case .Delete_File:
		history_delete_ask(app, ids)
	case .Remove:
		gone := clone_ids(ids)
		history_remove(&hw.history, gone)
		worker_send(&app.worker, Job_History(History_Remove{ids = gone}))
		app_announce(app, .Good, len(gone) == 1 ? i18n.tr("Removed from the history") : fmt.tprintf(i18n.tr("%d removed from the history"), len(gone)), len(gone) == 1 ? i18n.tr("The file stays.") : i18n.tr("The files stay."), history_window_of(app))
	case .Preview:
		// (a pane the user may have floated or docked elsewhere: it comes back where it was)
		if ui.view_is_open(&app.views, PREVIEW_VIEW) {
			ui.view_close(&app.views, PREVIEW_VIEW)
			history_preview_drop(app)
		} else {
			ui.view_open(&app.views, PREVIEW_VIEW, app, owner = &hw.host.state)
		}
	case .Select_All:
		// (one model for the grid and the list: every entry shown; the cursor stays where it is, else the first)
		sel := history_selection(hw)
		rows := history_rows(app)
		ui.item_selection_all(sel, rows)
		if sel.sel < 0 && rows.count > 0 { sel.sel = 0 }
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
	case .Keys:
		history_sheet_keep(app)
		ui.shortcuts_sheet_open(&hw.sheet, hw.sheet_table.commands, i18n.tr("Cliche's keys"), hw.sheet_table.version)
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
		app_announce(app, .Good, len(parts) == 1 ? one : several, "", history_window_of(app))
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

// The main window, for a toast where the system shows no notification: while it is shown.
@(private = "file")
history_window_of :: proc(app: ^App) -> ^host.Host {
	return app.history_window.visible ? &app.history_window.host : nil
}
