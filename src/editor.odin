package cliche

// The editor: a window where a picture just taken gets arrows, boxes, text and the rest: a workflow's Annotate step
// (workflow_app.odin) waits for it. Every annotation stays an object (editor_model.odin) until the picture is done: it is
// selected, moved, resized, recoloured or deleted, and every change is undone and redone.
//
// Each picture has an editor of its own (app.editors), any number open together: a second screenshot never waits for
// the first one's Done. An editor is known by its id (Editor.id): what the worker gives back for it (a copy's PNG, a
// save) carries that id, and finds it, or finds it gone. An editor closed is freed (editors_sweep), but for one kept
// hidden for the next picture (its window and surface ready: it shows at once) and the renderer's own window, which
// the other windows need.
//
// The window follows the settings' model (settings_view.odin): a host of its own; the theme of appearance.theme; the
// command palette (Ctrl+K) and the sheet of its keys (F1).
//
//   the bar      the tools (each an icon, a tooltip and a key), the properties of the tool or of the selection, then
//                undo, redo, copy, save, Cancel and Done
//   the canvas   the picture and its shapes (editor_export.odin paints them), the selection's handles, the crop
//
// The canvas takes the pointer itself (editor_input: its presses, releases and wheel never reach the widgets) and turns
// it into the model's events; the keys go through the commands' table, as the settings' do. A text being typed is a
// field of the toolkit's over the canvas.
//
// Done hands the flattened picture back to the run that asked for it (workflow_editor_done); a picture of the history
// runs the workflow of "Capture a region and edit". Cancel, or a close without Done, cancels the run's Annotate step
// (workflow_editor_closed): what needs its picture or its "done" is skipped, what hangs on its "cancelled" runs. Flattening runs on the GPU (an offscreen target read back a frame later); Ctrl+S encodes and
// writes the PNG on the worker (Job_Save). A file of the history is read and decoded by a task of the chores.

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:time"
import "core:strconv"
import "core:strings"
import config "gt:config"
import "gt:draw"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import png "gt:png"
import prefs_page "gt:prefs_page"
import "gt:render"
import tasks "gt:tasks"
import "gt:ui"
import i18n "gt:i18n"

EDITOR_SIZE :: [2]int{1180, 780}
EDITOR_DOUBLE_CLICK_MS :: 450
EDITOR_DOUBLE_CLICK_PX :: 5
EDITOR_HANDLE_SIDE :: 8     // a handle's side, logical pixels
EDITOR_CROP_DIM :: 0.55     // how dark the picture is outside the crop

// The actions of the bar, the keys, the palette and the sheet. The tools come first, in Edit_Tool's order. Nudge is
// last: the sheet lists it, the palette does not (the arrow keys are its own).
Editor_Action :: enum u8 {
	Tool_Select, Tool_Rectangle, Tool_Ellipse, Tool_Arrow, Tool_Line, Tool_Pen, Tool_Text, Tool_Highlighter,
	Tool_Pixelate, Tool_Step, Tool_Crop,
	Undo, Redo, Delete, Duplicate, Remove_Crop,
	Zoom_In, Zoom_Out, Zoom_Fit,
	Copy, Save, Done,
	Close, Palette, Keys,
	Nudge,
}

EDITOR_ACTIONS := [Editor_Action]ui.Command{
	.Tool_Select      = {label = i18n.later("Select and move"), group = i18n.later("Tools"), keys = {{.V, {}}, {}}, icon = lucide.MOUSE_POINTER_2, tags = {"pointer", "move", "resize"}},
	.Tool_Rectangle   = {label = i18n.later("Rectangle"), group = i18n.later("Tools"), keys = {{.R, {}}, {}}, icon = lucide.SQUARE, tags = {"box", "square", "frame"}},
	.Tool_Ellipse     = {label = i18n.later("Ellipse"), group = i18n.later("Tools"), keys = {{.E, {}}, {}}, icon = lucide.CIRCLE, tags = {"circle", "oval", "round"}},
	.Tool_Arrow       = {label = i18n.later("Arrow"), group = i18n.later("Tools"), keys = {{.A, {}}, {}}, icon = lucide.ARROW_UP_RIGHT, tags = {"point", "show"}},
	.Tool_Line        = {label = i18n.later("Line"), group = i18n.later("Tools"), keys = {{.L, {}}, {}}, icon = lucide.SLASH, tags = {"straight", "rule"}},
	.Tool_Pen         = {label = i18n.later("Pen"), group = i18n.later("Tools"), keys = {{.P, {}}, {}}, icon = lucide.PENCIL, tags = {"freehand", "draw", "brush"}},
	.Tool_Text        = {label = i18n.later("Text"), group = i18n.later("Tools"), keys = {{.T, {}}, {}}, icon = lucide.TYPE, tags = {"label", "write", "words"}},
	.Tool_Highlighter = {label = i18n.later("Highlighter"), group = i18n.later("Tools"), keys = {{.H, {}}, {}}, icon = lucide.HIGHLIGHTER, tags = {"marker", "yellow", "emphasis"}},
	.Tool_Pixelate    = {label = i18n.later("Pixelate"), group = i18n.later("Tools"), keys = {{.B, {}}, {}}, icon = lucide.LAYOUT_GRID, tags = {"blur", "hide", "censor", "mosaic", "redact"}},
	.Tool_Step        = {label = i18n.later("Step number"), group = i18n.later("Tools"), keys = {{.N, {}}, {}}, icon = lucide.LIST_ORDERED, tags = {"counter", "badge", "numbered"}},
	.Tool_Crop        = {label = i18n.later("Crop"), group = i18n.later("Tools"), keys = {{.C, {}}, {}}, icon = lucide.CROP, tags = {"cut", "trim"}},
	.Undo             = {label = i18n.later("Undo"), group = i18n.later("Edit"), keys = {{.Z, {.Ctrl}}, {}}, icon = lucide.UNDO_2, tags = {"back", "revert"}},
	.Redo             = {label = i18n.later("Redo"), group = i18n.later("Edit"), keys = {{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}}}, icon = lucide.REDO_2, tags = {"again", "forward"}},
	.Delete           = {label = i18n.later("Delete the selection"), group = i18n.later("Edit"), keys = {{.Delete, {}}, {.Backspace, {}}}, icon = lucide.TRASH_2, tags = {"remove", "erase"}},
	.Duplicate        = {label = i18n.later("Duplicate the selection"), group = i18n.later("Edit"), keys = {{.D, {.Ctrl}}, {}}, icon = lucide.COPY, tags = {"clone", "copy"}},
	.Remove_Crop      = {label = i18n.later("Remove the crop"), group = i18n.later("Edit"), icon = lucide.CROP, tags = {"uncrop", "whole", "reset"}},
	.Zoom_In          = {label = i18n.later("Zoom in"), group = i18n.later("View"), keys = {{.Equal, {.Ctrl}}, {.Num_Add, {.Ctrl}}}, icon = lucide.ZOOM_IN, tags = {"larger", "magnify"}},
	.Zoom_Out         = {label = i18n.later("Zoom out"), group = i18n.later("View"), keys = {{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}, icon = lucide.ZOOM_OUT, tags = {"smaller"}},
	.Zoom_Fit         = {label = i18n.later("Fit the picture to the window"), group = i18n.later("View"), keys = {{.N0, {.Ctrl}}, {}}, icon = lucide.MAXIMIZE, tags = {"zoom", "whole", "reset"}},
	.Copy             = {label = i18n.later("Copy the picture"), group = i18n.later("Picture"), keys = {{.C, {.Ctrl}}, {}}, icon = lucide.CLIPBOARD_COPY, tags = {"clipboard"}},
	.Save             = {label = i18n.later("Save the picture"), group = i18n.later("Picture"), keys = {{.S, {.Ctrl}}, {}}, icon = lucide.SAVE, tags = {"file", "png", "write"}},
	.Done             = {label = i18n.later("Done: the workflow goes on"), group = i18n.later("Picture"), keys = {{.Return, {}}, {}}, icon = lucide.CHECK, tags = {"finish", "apply", "upload", "ok"}},
	.Close            = {label = i18n.later("Close the editor"), group = i18n.later("Window"), keys = {{.W, {.Ctrl}}, {}}, icon = lucide.X, tags = {"discard", "cancel", "quit"}},
	.Palette          = {label = i18n.later("Command palette"), group = i18n.later("Window"), keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND, tags = {"actions", "search"}},
	.Keys             = {label = i18n.later("Keyboard shortcuts"), group = i18n.later("Window"), keys = {{.F1, {}}, {}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}},
	.Nudge            = {label = i18n.later("Move the selection a pixel (arrows; with Shift, ten)"), group = i18n.later("Edit"), keys = {{.Left, {}}, {.Left, {.Shift}}}, icon = lucide.MOUSE_POINTER_2, tags = {"nudge"}},
}

EDITOR_COLOR_NAMES := [len(EDIT_COLORS)]string{i18n.later("Red"), i18n.later("Orange"), i18n.later("Yellow"), i18n.later("Green"), i18n.later("Blue"), i18n.later("Purple"), i18n.later("Black"), i18n.later("White")}

// The mosaic of a picture, made by a task of the chores (it reads every pixel). The task owns this until `ended`.
Editor_Mosaic_Work :: struct {
	rgba:   []u8,   // the editor's picture, read only
	size:   [2]int,
	cell:   int,
	out:    Edit_Mosaic,
	cancel: bool,   // atomic: the picture goes, the task stops early
	ended:  sync.One_Shot_Event,
	app:    ^App,
}

// A PNG file read and decoded by a task of the chores (editor_open_file). Who frees it is whoever comes last: the task
// when the editor gave it up, else the editor once it is done (Load_State).
Editor_Load_Work :: struct {
	path:  string,   // owned
	rgba:  []u8,     // owned once read
	size:  [2]int,
	ok:    bool,
	state: Load_State,   // atomic
	app:   ^App,
}

Load_State :: enum i32 { Running, Done, Given_Up }

// The heap's (app.editors holds the pointers): its host must stay where it is while the window is open.
Editor :: struct {
	app:         ^App,
	id:          u64,          // stable for its life: what the worker's results for it name (never 0)
	ask:         Annotate_Ask, // the run and node its picture is for (run 0: none, as for a picture of the history)
	host:        host.Host,
	visible:     bool,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	palette:     ui.Command_Palette,
	sheet_open:  bool,
	asking:      bool,       // the question before the changes are dropped
	close_due:   bool,       // closed in a frame: acted on after it (editor_after_frame)
	done_due:    bool,       // Done with nothing changed, in a frame: acted on after it (what follows may open a window)

	model:       Edit_Model,
	has_picture: bool,
	shot:        Shot,       // the picture as taken (owned while has_picture)
	tex:         render.Texture,
	tex_size:    [2]int,
	mosaic:      Edit_Mosaic,
	mosaic_work: ^Editor_Mosaic_Work,
	load_work:   ^Editor_Load_Work,   // a file being read (editor_open_file)
	load_problem: string,             // why the file could not be shown (static text; "" none)

	field:        ui.Text_Field,   // the text being typed
	field_typing: u32,             // the model's Typing count the field was filled for
	field_rect:   Edit_Box,        // where the field was last built, window pixels
	field_shown:  bool,

	pointer:     Edit_Vec,   // window pixels
	has_pointer: bool,
	space:       bool,       // Space held: a left drag pans
	hover:       platform.Cursor,   // the canvas' cursor where the pointer rests
	last_press:  time.Tick,
	last_press_at: Edit_Vec,

	export:      Edit_Export,
	exporting:   bool,

	// what the canvas' draw needs of the interface, taken at each build (the draw runs outside it)
	accent:      draw.Color,
	scale:       f32,
}

// Shows `shot` (taken: the editor owns it now) in `ed`. `scale`: the picture's pixels per logical pixel (2 for a
// picture of a screen at 200 %). False: the picture cannot be held; the shot is freed.
editor_open_shot :: proc(ed: ^Editor, shot: Shot, scale: f32 = 1) -> bool {
	app := ed.app
	shot := shot
	timing_mark("editor window open")
	editor_picture_drop(ed)
	editor_load_stop(ed)
	ed.load_problem = ""
	r := &app.shared.r
	w, h := shot.size.x, shot.size.y
	if ed.tex != 0 && ed.tex_size != shot.size {
		render.destroy_texture(r, ed.tex)
		ed.tex = 0
	}
	if ed.tex == 0 {
		ed.tex = render.create_texture_rgba(r, w, h, mips = true)
		ed.tex_size = shot.size
	}
	if ed.tex == 0 {
		log.error("the editor cannot hold the picture")
		shot_free(&shot)
		return false
	}
	// (mips: a picture shown smaller than its pixels stays sharp, not grainy)
	render.update_texture_rgba(r, ed.tex, 0, 0, w, h, shot.rgba)
	timing_mark("picture uploaded")
	ed.shot, ed.has_picture = shot, true
	edit_model_init(&ed.model, shot.size, scale, editor_measure, app)
	editor_choices_load(app, &ed.model)
	ed.field_typing = 0
	ed.asking, ed.close_due, ed.done_due, ed.exporting = false, false, false, false
	editor_mosaic_start(ed, int(math.round(EDIT_PIXELATE_CELL * ed.model.doc.scale)))
	editor_show(ed)
	timing_mark("editor shown")
	return true
}

// Shown, or brought to the front, with the activation token of the command that asked for it.
@(private = "file")
editor_show :: proc(ed: ^Editor) {
	token := app_take_token(ed.app)
	defer delete(token)
	if !ed.visible {
		host.host_show(&ed.host)
		ed.visible = true
	}
	platform.raise_window_token(ed.host.win, token)
	ed.host.settle = max(ed.host.settle, 3)
}

// An editor for a new picture: the one kept hidden for it, else a new window. nil: no window can open.
editor_take :: proc(app: ^App) -> ^Editor {
	timing_mark("editor asked")
	for ed in app.editors {
		if editor_free_for_picture(ed) { return ed }
	}
	return editor_open(app, headless = false)
}

// Hidden, with no picture and none being read: closed, or opened ahead of its first picture.
@(private = "file")
editor_free_for_picture :: proc(ed: ^Editor) -> bool {
	return !ed.visible && !ed.has_picture && ed.load_work == nil
}

// The PNG file at `path` (not kept) in an editor of its own, read and decoded by a task of the chores: the window
// says so meanwhile, and says why when the file cannot be read.
editor_open_file :: proc(app: ^App, path: string) {
	ed := editor_take(app)
	if ed == nil { return }
	ed.ask = {}
	ed.load_problem = ""
	work := new(Editor_Load_Work)
	work^ = {path = strings.clone(path), app = app}
	if tasks.add(ui.chores(), editor_load_run, work) {
		ed.load_work = work
	} else {
		delete(work.path)
		free(work)
		ed.load_problem = i18n.tr("The picture cannot be read.")
	}
	editor_show(ed)
}

@(private = "file")
editor_load_run :: proc(data: rawptr) {
	work := (^Editor_Load_Work)(data)
	if bytes, err := os.read_entire_file(work.path, context.allocator); err == nil {
		rgba, w, h, ok := png.decode(bytes)
		delete(bytes)
		if ok { work.rgba, work.size, work.ok = rgba, {w, h}, true }
	}
	app := work.app
	if _, done := sync.atomic_compare_exchange_strong(&work.state, .Running, .Done); done {
		app_wake(app)
		return
	}
	// (the editor gave it up meanwhile: nobody takes it)
	editor_load_free(work)
}

@(private = "file")
editor_load_free :: proc(work: ^Editor_Load_Work) {
	delete(work.path)
	delete(work.rgba)
	free(work)
}

// Opens a new editor's window (hidden) and adds it to app.editors. `headless`: offscreen, on the software renderer
// (shots, tests). nil: the window cannot open.
editor_open :: proc(app: ^App, headless: bool) -> ^Editor {
	ed := new(Editor)
	app.editor_next_id += 1
	ed.app, ed.id = app, app.editor_next_id
	if !host.host_open(&ed.host, &app.shared, {title = "cliche editor", size = EDITOR_SIZE, headless = headless}, editor_build, ed) {
		log.error("the editor's window cannot open")
		free(ed)
		return nil
	}
	app_standard_follow(app, &ed.host)
	ed.host.input = editor_input
	ed.host.close_asked = editor_host_close
	ed.host.params = editor_params
	ed.host.after_input = 3
	ed.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	ed.host.state.icon_font = ed.icons
	append(&app.editors, ed)
	app_wake_add(app, ed.host.win)
	return ed
}

// The editor of id `id`; nil: it is closed and freed (a result of the worker for it comes too late).
editor_find :: proc(app: ^App, id: u64) -> ^Editor {
	for ed in app.editors { if ed.id == id { return ed } }
	return nil
}

// After a frame of the editor: a file read, the mosaic made, the flattened picture read, a close acted on. What its
// picture was for goes on last: that may give this editor a new picture (editor_take).
editor_after_frame :: proc(ed: ^Editor) {
	editor_load_take(ed)
	editor_mosaic_take(ed)
	if ed.exporting { editor_export_poll(ed) }
	if ed.done_due {
		// (the picture as it was taken: nothing to draw)
		ed.done_due = false
		shot := ed.shot
		ed.shot, ed.has_picture = {}, false
		editor_choices_keep(ed.app, &ed.model)
		edit_model_destroy(&ed.model)
		editor_done(ed, shot)
		return
	}
	if ed.close_due {
		ed.close_due = false
		ask := ed.ask
		editor_close(ed)   // (the picture goes: nothing is copied, saved or told; the capture's flow was over already)
		workflow_editor_closed(ed.app, ask)   // (its run's branch stops)
	}
}

// The editors closed since the last turn are freed, but for one kept hidden for the next picture (it shows at once)
// and the renderer's own window (the other windows draw with its renderer: it is hidden, never closed). Not inside a
// frame of an editor.
editors_sweep :: proc(app: ^App) {
	kept := false
	for ed in app.editors {
		// (closed while its file was read: the read is let go once done, without a wait here)
		if !ed.visible { editor_load_take(ed) }
		if editor_free_for_picture(ed) && app.shared.main == &ed.host { kept = true }
	}
	for i := len(app.editors) - 1; i >= 0; i -= 1 {
		ed := app.editors[i]
		if !editor_free_for_picture(ed) || app.shared.main == &ed.host { continue }
		if !kept { kept = true; continue }
		editor_dispose(ed)
	}
}

// The editor's window closed and its state freed; it leaves app.editors. Not for the renderer's own window while
// another window is open.
editor_dispose :: proc(ed: ^Editor) {
	app := ed.app
	for e, i in app.editors {
		if e == ed { ordered_remove(&app.editors, i); break }
	}
	// (no other thread wakes a window about to go)
	app_wake_remove(app, ed.host.win)
	editor_destroy(ed)
	app_host_close(app, &ed.host)
	editor_free(ed)
	free(ed)
}

// The file, once its task is done: shown, or why not.
@(private = "file")
editor_load_take :: proc(ed: ^Editor) {
	work := ed.load_work
	if work == nil || sync.atomic_load(&work.state) != .Done { return }
	ed.load_work = nil
	delete(work.path)
	ok, rgba, size := work.ok, work.rgba, work.size
	free(work)
	if !ed.visible {
		delete(rgba)   // (closed while the file was read: nobody waits for it)
		return
	}
	if !ok {
		ed.load_problem = i18n.tr("The picture cannot be read: it is not a PNG file, or it is gone.")
		ed.host.settle = max(ed.host.settle, 2)
		return
	}
	editor_open_shot(ed, {rgba = rgba, size = size, source = .Region})
}

// Before the window closes for good, or another picture comes: a file being read is given up, without a wait.
@(private = "file")
editor_load_stop :: proc(ed: ^Editor) {
	work := ed.load_work
	if work == nil { return }
	ed.load_work = nil
	if _, given_up := sync.atomic_compare_exchange_strong(&work.state, .Running, .Given_Up); given_up { return }   // (its task frees it)
	editor_load_free(work)
}

// What the worker said of a save asked from an editor (Ctrl+S): told as cliche tells (app_announce), in that editor
// when it is still shown. The file is written either way: a closed editor's save is still said.
editor_saved :: proc(app: ^App, r: Result_Saved) {
	defer delete(r.path)
	window := editor_window(app, r.editor)
	if r.error != .None { app_announce(app, .Bad, i18n.tr("Not saved"), i18n.tr(FLOW_ERROR_TEXT[r.error]), window) } else { app_announce(app, .Good, i18n.tr("Saved"), r.path, window) }
}

// Where a message for editor `id` is shown: its window while it is shown; nil (cliche's usual place) once it is not.
@(private = "file")
editor_window :: proc(app: ^App, id: u64) -> ^host.Host {
	ed := editor_find(app, id)
	return ed != nil && ed.visible ? &ed.host : nil
}

// The texture goes with the renderer: before the windows close.
editor_destroy :: proc(ed: ^Editor) {
	editor_picture_drop(ed)
	if ed.tex != 0 { render.destroy_texture(&ed.app.shared.r, ed.tex) }
	ed.tex = 0
}

editor_free :: proc(ed: ^Editor) {
	editor_load_stop(ed)
	editor_picture_drop(ed)
	ui.palette_destroy(&ed.palette)
	ui.field_destroy(&ed.field)
}

// The window hidden, the picture and its shapes let go: editors_sweep frees it, or keeps it for the next picture.
@(private = "file")
editor_close :: proc(ed: ^Editor) {
	ed.palette.open = false
	ed.sheet_open = false
	ed.asking = false
	ed.ask = {}
	if ed.visible {
		host.host_hide(&ed.host)
		ed.visible = false
	}
	editor_picture_drop(ed)
}

@(private = "file")
editor_picture_drop :: proc(ed: ^Editor) {
	if ed.has_picture { editor_choices_keep(ed.app, &ed.model) }
	editor_mosaic_stop(ed)
	edit_mosaic_free(&ed.mosaic)
	edit_export_free(&ed.export)
	ed.exporting = false
	if !ed.has_picture { return }
	edit_model_destroy(&ed.model)
	shot_free(&ed.shot)
	ed.has_picture = false
}

// The size of a text in the window's font (the model's measure).
@(private = "file")
editor_measure :: proc(user: rawptr, text: string, size: f32) -> Edit_Vec {
	app := (^App)(user)
	m := font.metrics(&app.shared.fonts, app.shared.font, size)
	return {font.text_width(&app.shared.fonts, app.shared.font, size, text), m.line_height}
}

////////////////////////////////
// The mosaic's task

@(private = "file")
editor_mosaic_start :: proc(ed: ^Editor, cell: int) {
	work := new(Editor_Mosaic_Work)
	work^ = {rgba = ed.shot.rgba, size = ed.shot.size, cell = cell, app = ed.app}
	run :: proc(data: rawptr) {
		work := (^Editor_Mosaic_Work)(data)
		work.out = edit_mosaic_make(work.rgba, work.size, work.cell, &work.cancel)
		app := work.app   // (read first: once ended, the editor may free the work)
		sync.one_shot_event_signal(&work.ended)
		app_wake(app)
	}
	if !tasks.add(ui.chores(), run, work) {
		free(work)
		return   // (the chores are stopping: a pixelated box stays grey)
	}
	ed.mosaic_work = work
}

// The mosaic, once its task is done.
@(private = "file")
editor_mosaic_take :: proc(ed: ^Editor) {
	if ed.mosaic_work == nil || sync.atomic_load(&ed.mosaic_work.ended.state) == 0 { return }
	edit_mosaic_free(&ed.mosaic)
	ed.mosaic = ed.mosaic_work.out
	free(ed.mosaic_work)
	ed.mosaic_work = nil
	ed.host.settle = max(ed.host.settle, 1)
}

// Before the picture goes: the task reads it. Told to stop, it ends within a row of cells, and is waited for.
@(private = "file")
editor_mosaic_stop :: proc(ed: ^Editor) {
	if ed.mosaic_work == nil { return }
	sync.atomic_store(&ed.mosaic_work.cancel, true)
	sync.one_shot_event_wait(&ed.mosaic_work.ended)
	edit_mosaic_free(&ed.mosaic_work.out)
	free(ed.mosaic_work)
	ed.mosaic_work = nil
}

////////////////////////////////
// Input

// Each build: the theme, as the main window has it.
@(private = "file")
editor_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	ed := (^Editor)(h.user)
	app := ed.app
	a := app.settings.appearance
	choice := prefs_page.appearance_choice(a)
	choice.glow = 1
	if ui.theme_show(&app.shared.theme, app.themes_file.all[:], choice, &ed.theme_shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !ed.theme_shown.light)
	}
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
}

// The window's close (its title bar's, Alt+F4): a file being read, or one that could not be, closes at once; a picture
// asks first when it has changes (editor_close_asked), its question drawn.
@(private = "file")
editor_host_close :: proc(h: ^host.Host) {
	ed := (^Editor)(h.user)
	if !ed.has_picture { ed.close_due = true; return }
	editor_close_asked(ed)
	h.settle = max(h.settle, 2)
}

// The canvas' pointer goes to the model; the rest to the widgets. A press is the canvas' when it lands on it with no
// dialog or menu open, and not on the text field; a release, a move or the wheel when a gesture goes on.
@(private = "file")
editor_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	ed := (^Editor)(h.user)
	m := &ed.model
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	if !ed.has_picture {
		return events
	}
	blocked := ed.palette.open || ed.sheet_open || ed.asking || ed.exporting || ui.ctx_menu_any_open()
	_, typing := m.mode.(Edit_Typing)
	for e in events {
		#partial switch e.kind {
		case .Key_Press:
			if e.key == .Space && !typing && !blocked && !e.repeat { ed.space = true }
		case .Key_Release:
			if e.key == .Space { ed.space = false }
		case .Mouse_Move:
			ed.pointer, ed.has_pointer = e.pos, true
			if !edit_idle(m) && !typing { edit_step(m, Edit_Move{at = e.pos, shift = .Shift in e.mods}) }
			editor_hover(ed)
		case .Mouse_Leave:
			ed.has_pointer = false
		case .Mouse_Press:
			ed.pointer, ed.has_pointer = e.pos, true
			if blocked || !edit_box_contains(m.view.canvas, e.pos) { break }
			if typing && edit_box_contains(ed.field_rect, e.pos) { break }
			button: Edit_Button
			#partial switch e.button {
			case .Left:   button = .Left
			case .Middle: button = .Middle
			case .Right:  button = .Right
			case:         continue
			}
			double := button == .Left && time.tick_diff(ed.last_press, e.stamp) < EDITOR_DOUBLE_CLICK_MS * time.Millisecond &&
				abs(e.pos.x - ed.last_press_at.x) <= EDITOR_DOUBLE_CLICK_PX && abs(e.pos.y - ed.last_press_at.y) <= EDITOR_DOUBLE_CLICK_PX
			if button == .Left { ed.last_press, ed.last_press_at = e.stamp, e.pos }
			edit_step(m, Edit_Press{at = e.pos, button = button, shift = .Shift in e.mods, pan = ed.space, double = double})
			_, typing = m.mode.(Edit_Typing)
			editor_hover(ed)
			continue
		case .Mouse_Release:
			if edit_idle(m) || typing { break }
			button := Edit_Button.Left
			if e.button == .Middle { button = .Middle } else if e.button == .Right { button = .Right }
			edit_step(m, Edit_Release{at = e.pos, button = button, shift = .Shift in e.mods})
			editor_hover(ed)
			continue
		case .Scroll:
			if blocked || !edit_box_contains(m.view.canvas, e.pos) { break }
			edit_step(m, Edit_Wheel{at = e.pos, delta = e.delta, zoom = .Ctrl in e.mods, sideways = .Shift in e.mods})
			continue
		}
		append(&out, e)
	}
	return out[:]
}

// The cursor of the canvas where the pointer is: what a press there would do. (On a move, not at each frame.)
@(private = "file")
editor_hover :: proc(ed: ^Editor) {
	m := &ed.model
	switch s in m.mode {
	case Edit_Panning:  ed.hover = .Grabbing; return
	case Edit_Moving:   ed.hover = .Move; return
	case Edit_Resizing: ed.hover = handle_cursor(s.handle); return
	case Edit_Drawing, Edit_Cropping: ed.hover = .Crosshair; return
	case Edit_Typing:   ed.hover = .Text; return
	case Edit_Idle:
	}
	switch {
	case ed.space:                          ed.hover = .Grab; return
	case !ed.has_pointer:                   ed.hover = .Arrow; return
	}
	p := edit_to_picture(m.view, ed.pointer)
	if m.tool != .Crop {
		if h := edit_handle_hit(&m.doc, p, EDIT_HANDLE_PX / m.view.zoom); h != .None { ed.hover = handle_cursor(h); return }
		hit := edit_hit(&m.doc, p, EDIT_HIT_PX / m.view.zoom)
		if hit >= 0 && (m.tool == .Select || hit == m.doc.selected) { ed.hover = .Move; return }
		if hit >= 0 && m.doc.shapes[hit].kind == .Text && m.tool == .Text { ed.hover = .Text; return }
	}
	switch m.tool {
	case .Select: ed.hover = .Arrow
	case .Text:   ed.hover = .Text
	case .Rectangle, .Ellipse, .Arrow, .Line, .Pen, .Highlighter, .Pixelate, .Step, .Crop: ed.hover = .Crosshair
	}
}

@(private = "file")
handle_cursor :: proc(h: Edit_Handle) -> platform.Cursor {
	switch h {
	case .Top_Left, .Bottom_Right: return .Resize_NWSE
	case .Top_Right, .Bottom_Left: return .Resize_NESW
	case .Top, .Bottom:            return .Resize_V
	case .Left, .Right:            return .Resize_H
	case .Start, .End:             return .Crosshair
	case .None:
	}
	return .Arrow
}

////////////////////////////////
// Actions

@(private = "file")
editor_action_enabled :: proc(ed: ^Editor, a: Editor_Action) -> bool {
	m := &ed.model
	if !ed.has_picture || ed.exporting || ed.done_due { return a == .Close || a == .Palette || a == .Keys }
	#partial switch a {
	case .Undo:                         return edit_can_undo(m)
	case .Redo:                         return edit_can_redo(m)
	case .Delete, .Duplicate, .Nudge:   return edit_idle(m) && edit_has_selection(m)
	case .Remove_Crop:                  return edit_idle(m) && m.doc.has_crop
	}
	return true
}

@(private = "file")
editor_action :: proc(ed: ^Editor, a: Editor_Action) {
	m := &ed.model
	switch a {
	case .Tool_Select, .Tool_Rectangle, .Tool_Ellipse, .Tool_Arrow, .Tool_Line, .Tool_Pen, .Tool_Text, .Tool_Highlighter,
	     .Tool_Pixelate, .Tool_Step, .Tool_Crop:
		edit_tool_set(m, Edit_Tool(int(a) - int(Editor_Action.Tool_Select)))
	case .Undo:        edit_undo(m)
	case .Redo:        edit_redo(m)
	case .Delete:      edit_delete(m)
	case .Duplicate:   edit_duplicate(m)
	case .Remove_Crop: edit_crop_clear(m)
	case .Zoom_In:     edit_view_zoom_centre(m, EDIT_ZOOM_STEP)
	case .Zoom_Out:    edit_view_zoom_centre(m, 1 / EDIT_ZOOM_STEP)
	case .Zoom_Fit:    edit_view_fit(m)
	case .Copy:        editor_export_start(ed, .Copy)
	case .Save:        editor_export_start(ed, .Save)
	case .Done:        editor_export_start(ed, .Done)
	case .Close:       editor_close_asked(ed)
	case .Palette:     ui.palette_open(&ed.palette)
	case .Keys:        ed.sheet_open = true
	case .Nudge:       edit_nudge(m, {1, 0})
	}
	editor_hover(ed)
}

// A close asked (the window's button, Escape, Ctrl+W): at once with nothing changed, else after the question.
editor_close_asked :: proc(ed: ^Editor) {
	if ed.exporting || ed.done_due { return }
	if ed.has_picture && edit_changed(&ed.model) { ed.asking = true } else { ed.close_due = true }
}

// The picture flattened for `purpose`. A text being typed is kept first. Done with nothing changed hands the picture as
// it was taken: nothing to draw.
@(private = "file")
editor_export_start :: proc(ed: ^Editor, purpose: Edit_Export_Purpose) {
	m := &ed.model
	if !ed.has_picture || ed.exporting || ed.done_due { return }
	if _, typing := m.mode.(Edit_Typing); typing { edit_step(m, Edit_Type_End{keep = true}) }
	if !edit_idle(m) { return }
	if purpose == .Done && !edit_changed(m) {
		// (after the frame, not in this build: the run may open another editor's window)
		ed.done_due = true
		return
	}
	edit_export_begin(&ed.export, purpose, &m.doc)
	ed.exporting = true
	ed.host.settle = max(ed.host.settle, 2)
}

// The flattened picture, once read back: to the workflow, the clipboard or a file.
@(private = "file")
editor_export_poll :: proc(ed: ^Editor) {
	app := ed.app
	shot, status := edit_export_poll(&app.shared.r, &ed.export, ed.shot.source)
	switch status {
	case .Pending, .None:
		ed.host.settle = max(ed.host.settle, 2)   // (frames go on until the copy is read)
		return
	case .Failed:
		purpose := ed.export.purpose
		edit_export_free(&ed.export)
		ed.exporting = false
		app_announce(app, .Bad, i18n.tr("The picture could not be made"), purpose == .Done ? i18n.tr("Nothing was done with it.") : "", &ed.host)
		return
	case .Ready:
	}
	purpose := ed.export.purpose
	edit_export_free(&ed.export)
	ed.exporting = false
	switch purpose {
	case .Done:
		editor_done(ed, shot)
	case .Copy:
		// (its PNG is made on the worker: editor_copied puts it on the clipboard)
		worker_send(&app.worker, Job_Copy_Encode{editor = ed.id, shot = shot})
	case .Save:
		worker_send(&app.worker, Job_Save{editor = ed.id, shot = shot, folder = strings.clone(app.settings.folder), pattern = strings.clone(app.settings.name_pattern)})
	}
}

// Done: the editor closes, and its picture (`shot`, taken) goes on in the run's branch it came for. Last: the run may
// give this editor its next picture.
@(private = "file")
editor_done :: proc(ed: ^Editor, shot: Shot) {
	ask := ed.ask
	editor_close(ed)
	workflow_editor_done(ed.app, ask, shot)
}

////////////////////////////////
// The window's interface

@(private = "file")
editor_build :: proc(h: ^host.Host, size: host.Vec2) {
	ed := (^Editor)(h.user)
	em := ui.font_size()
	if !ed.has_picture {
		editor_waiting(ed, em)
		return
	}
	m := &ed.model
	ed.accent, ed.scale = ui.color("accent"), ui.scale()

	// (while a text is typed, its field has the keys: no command takes a letter from it)
	_, typing := m.mode.(Edit_Typing)
	dialog := ed.palette.open || ed.sheet_open || ed.asking
	if !dialog && !typing && !ed.exporting {
		if ui.key_press(.Escape) {
			if !edit_deselect(m) { editor_close_asked(ed) }
		}
		editor_nudge_keys(ed)
		for a in Editor_Action {
			if a == .Nudge { continue }
			if ui.command_pressed(EDITOR_ACTIONS[a], editor_action_enabled(ed, a)) { editor_action(ed, a); break }
		}
	}

	canvas: ui.Rect
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###editor") {   // (the theme's surface: the host only clears to black)
		editor_bar(ed, em)
		ui.next({width = ui.fill(), height = ui.fill(), cursor = ed.hover, bg = ui.color("well")})
		b := ui.build_box({.Clickable, .Clip, .Draw_Background}, "###canvas")
		b.custom, b.custom_user = editor_canvas_draw, ed
		_ = ui.signal(b)
		canvas = b.rect   // (last frame's layout: where the canvas is)
	}
	// (after the canvas: drawn over it, and first for the pointer)
	editor_text_field(ed, em)
	editor_dialogs(ed)
	// (the toasts at the bottom of the canvas: over the bar they hid the buttons just pressed)
	if canvas.max.x > canvas.min.x { ui.set_toast_area(canvas) }
	ui.set_toast_position(&ed.host.state, .Bottom_Center)
}

// No picture yet: a file is read, or could not be. Escape closes.
@(private = "file")
editor_waiting :: proc(ed: ^Editor, em: f32) {
	if ui.key_press(.Escape) || ui.command_pressed(EDITOR_ACTIONS[.Close]) { ed.close_due = true }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center})
	if ui.column(id = "###waiting") {
		ui.spacer(ui.pct(0.4))
		text := ed.load_problem != "" ? ed.load_problem : i18n.tr("Reading the picture…")
		if ui.tags(ed.load_problem != "" ? "bad" : "weak") {
			ui.next({width = ui.text_size(em), height = ui.px(em * 2)})
			ui.label(fmt.tprintf("%s###waiting_text", text))
		}
	}
}

@(private = "file")
editor_nudge_keys :: proc(ed: ^Editor) {
	m := &ed.model
	if !edit_idle(m) || !edit_has_selection(m) { return }
	@(static, rodata) dirs := [4]platform.Key{.Left, .Right, .Up, .Down}
	@(static, rodata) steps := [4]Edit_Vec{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	for k, i in dirs {
		if ui.key_press(k) { edit_nudge(m, steps[i]) }
		if ui.key_press(k, {.Shift}) { edit_nudge(m, steps[i] * EDIT_NUDGE_FAST) }
	}
}

// The field of the text being typed, over the canvas where the text is.
@(private = "file")
editor_text_field :: proc(ed: ^Editor, em: f32) {
	app := ed.app
	m := &ed.model
	s, typing := m.mode.(Edit_Typing)
	if !typing {
		if ed.field_shown { ui.set_focus(0) }
		ed.field_shown = false
		return
	}
	sh := &m.doc.shapes[s.index]
	fresh := ed.field_typing != m.typing
	if fresh {
		ed.field_typing = m.typing
		ui.field_set(&ed.field, sh.text)
		ui.field_select_all(&ed.field)
	}
	size := max(edit_text_px(&m.doc, sh) * m.view.zoom, em * 0.8)
	at := edit_to_window(m.view, sh.a)
	pad := math.round(em * 0.3)
	text_w := font.text_width(&app.shared.fonts, app.shared.font, size, ui.field_string(&ed.field))
	w := max(text_w + 2 * pad + size, em * 8)
	hgt := math.round(font.metrics(&app.shared.fonts, app.shared.font, size).line_height + 2 * pad)
	ed.field_rect = {at - pad, at - pad + {w, hgt}}
	ui.next({fixed_x = at.x - pad, fixed_y = at.y - pad, width = ui.px(w), height = ui.px(hgt), font_size = size, text_pad = pad, fg = edit_color(sh.style.color)})
	res := ui.line_edit("###edit_text", &ed.field, placeholder = i18n.tr("Text"), menu = false)
	if fresh || !ed.field_shown { ui.set_focus(res.box.key) }
	ed.field_shown = true
	// (what was typed in the frame of Enter is kept with it)
	if res.changed { edit_step(m, Edit_Typed{text = ui.field_string(&ed.field)}) }
	if res.committed {
		edit_step(m, Edit_Type_End{keep = true})
	} else if res.cancelled {
		edit_step(m, Edit_Type_End{keep = false})
	}
}

// The bar: the tools, the properties, then what is done with the picture.
@(private = "file")
editor_bar :: proc(ed: ^Editor, em: f32) {
	m := &ed.model
	side := math.round(em * 2.2)
	ui.next({width = ui.fill(), height = ui.px(side + math.round(em * 0.8)), axis = .X, cross = .Center})
	if ui.row(id = "###bar") {
		ui.spacer(ui.px(em * 0.5))
		for t in Edit_Tool {
			a := Editor_Action(int(Editor_Action.Tool_Select) + int(t))
			if bar_icon(fmt.tprintf("tool%d", int(t)), EDITOR_ACTIONS[a], side, active = m.tool == t, enabled = true) { editor_action(ed, a) }
		}
		bar_separator(em, side)
		editor_properties(ed, em, side)
		ui.spacer(ui.fill())
		for a in ([?]Editor_Action{.Undo, .Redo, .Copy, .Save}) {
			if bar_icon(fmt.tprintf("act%d", int(a)), EDITOR_ACTIONS[a], side, active = false, enabled = editor_action_enabled(ed, a)) { editor_action(ed, a) }
		}
		ui.spacer(ui.px(em * 0.5))
		// (Cancel ends the workflow's step as given up: what hangs on its "cancelled" runs, what needs its picture does not)
		ui.next({width = ui.text_size(em * 1.2), height = ui.px(side), radius = em * 0.4})
		if ui.button(fmt.tprintf("%s###cancel", i18n.tr("Cancel")), tip = ui.command_tip(EDITOR_ACTIONS[.Close])).clicked { editor_action(ed, .Close) }
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.text_size(em * 1.2), height = ui.px(side), radius = em * 0.4})
		if ui.button(fmt.tprintf("%s###done", i18n.tr("Done")), intent = .Primary, tip = ui.command_tip(EDITOR_ACTIONS[.Done])).clicked && editor_action_enabled(ed, .Done) { editor_action(ed, .Done) }
		ui.spacer(ui.px(em * 0.5))
	}
}

// The properties of the selection, else of the tool: what applies to its kind only.
@(private = "file")
editor_properties :: proc(ed: ^Editor, em: f32, side: f32) {
	m := &ed.model
	style, props := edit_style_shown(m)
	if props == {} { return }
	before := style
	if .Color in props {
		for c, i in EDIT_COLORS {
			if swatch(fmt.tprintf("swatch%d", i), c, i18n.tr(EDITOR_COLOR_NAMES[i]), style.color == c, math.round(side * 0.62)) { style.color = c }
			ui.spacer(ui.px(math.round(em * 0.25)))
		}
		bar_separator(em, side)
	}
	if .Width in props {
		// (a slider for the feel, its field for the exact width)
		ui.next({width = ui.px(math.round(em * 13)), height = ui.px(math.round(side * 0.85))})
		ui.number("###width", &style.width, lo = f32(EDIT_WIDTH_MIN), hi = f32(EDIT_WIDTH_MAX), step = 1, unit = "px", track = true)
		ui.spacer(ui.px(em * 0.5))
	}
	if .Text_Size in props {
		labels := [len(EDIT_TEXT_SIZES)]string{i18n.tr("text size, short", "S"), i18n.tr("text size, short", "M"), i18n.tr("text size, short", "L"), i18n.tr("text size, short", "XL")}
		tips := [len(EDIT_TEXT_SIZES)]string{i18n.tr("Small text"), i18n.tr("Medium text"), i18n.tr("Large text"), i18n.tr("Very large text")}
		at := 0
		for v, i in EDIT_TEXT_SIZES { if v == style.text_size { at = i } }
		ui.next({width = ui.px(em * 10), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###text_size", labels[:], &at, tips[:]) { style.text_size = EDIT_TEXT_SIZES[at] }
		ui.spacer(ui.px(em * 0.5))
	}
	if .Shadow in props {
		// (its softness: 0, none)
		ui.next({height = ui.px(side), text_pad = 0})
		ui.label(fmt.tprintf("%s###shadow_label", i18n.tr("Shadow")))
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(math.round(em * 12)), height = ui.px(math.round(side * 0.85))})
		ui.number("###shadow", &style.shadow, lo = f32(0), hi = f32(EDIT_SHADOW_MAX), step = 1, unit = "px", track = true)
		ui.spacer(ui.px(em * 0.5))
	}
	if .Fill in props {
		ui.next({height = ui.px(side)})
		ui.toggle("###fill", i18n.tr("Fill"), &style.fill)
	}
	if style != before { edit_style_set(m, style) }
}

// An icon of the bar: its command's tooltip; `active`: the tool in use.
@(private = "file")
bar_icon :: proc(id: string, c: ui.Command, side: f32, active, enabled: bool) -> bool {
	ui.next({width = ui.px(side), height = ui.px(side), radius = math.round(side * 0.22), font_size = math.round(side * 0.5)})
	return ui.icon_button(id, c.icon, tip = ui.command_tip(c), face = active ? .Toggled : .Ghost, intent = active ? .Primary : .Neutral, disabled = !enabled).clicked && enabled
}

@(private = "file")
bar_separator :: proc(em, side: f32) {
	ui.spacer(ui.px(math.round(em * 0.45)))
	ui.next({width = ui.px(max(math.round(ui.scale()), 1)), height = ui.px(math.round(side * 0.7)), bg = ui.color("border")})
	ui.build_box({.Draw_Background}, "")
	ui.spacer(ui.px(math.round(em * 0.45)))
}

@(private = "file")
Swatch_Draw :: struct { color, ring: draw.Color, chosen: bool, scale: f32 }

// A colour to choose: a disc, a ring around the one chosen.
@(private = "file")
swatch :: proc(id: string, rgb: u32, name: string, chosen: bool, side: f32) -> bool {
	d := ui.frame_new(Swatch_Draw)
	d^ = {color = edit_color(rgb), ring = ui.color("text"), chosen = chosen, scale = ui.scale()}
	ui.next({width = ui.px(side), height = ui.px(side)})
	b := ui.custom(fmt.tprintf("###%s", id), proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Swatch_Draw)(user)
		r := b.rect
		half := (r.max.x - r.min.x) * 0.5
		inner := draw.rect_pad(r, -math.round(2 * d.scale))
		draw.rect(dc, inner, d.color, half)
		// (a hairline: black and white swatches show on any theme)
		draw.rect(dc, inner, {0.5, 0.5, 0.5, 0.6}, half, max(d.scale, 1))
		if d.chosen { draw.rect(dc, r, d.ring, half, max(math.round(1.5 * d.scale), 1)) }
	}, d, {.Clickable, .Draw_Hot_Effects})
	sig := ui.signal(b)
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(name) } }
	return sig.clicked
}

// The palette (every action but the arrows), the sheet of keys, the question before the changes are dropped.
@(private = "file")
editor_dialogs :: proc(ed: ^Editor) {
	all := slice.enumerated_array(&EDITOR_ACTIONS)
	if ed.palette.open {
		listed := all[:len(all) - 1]   // (Nudge: its keys are the arrows)
		enabled := make([]bool, len(listed), context.temp_allocator)
		for i in 0 ..< len(listed) { enabled[i] = editor_action_enabled(ed, Editor_Action(i)) }
		if i, _ := ui.palette(&ed.palette, listed, enabled); i >= 0 { editor_action(ed, Editor_Action(i)) }
	}
	ui.shortcuts_sheet("keys", all, &ed.sheet_open, i18n.tr("The editor's keys"))
	switch ui.confirm("drop", &ed.asking, {title = i18n.tr("Close the editor and drop the changes?"), note = i18n.tr("The annotations on this picture are lost. Nothing is copied or saved."), act = i18n.tr("Drop the changes")}) {
	case .Confirmed: ed.close_due = true
	case .Cancelled, .None:
	}
}

////////////////////////////////
// The canvas

// The canvas' draw: the picture and its shapes, the crop, the selection's handles; then the export, when one is due.
@(private = "file")
editor_canvas_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	ed := (^Editor)(user)
	app := ed.app
	m := &ed.model
	if !ed.has_picture || ed.tex == 0 { return }
	// (the view follows the canvas of this frame: the next input is placed by it)
	edit_view_place(m, {b.rect.min, b.rect.max})
	skip := -1
	if s, typing := m.mode.(Edit_Typing); typing { skip = s.index }
	mosaic: ^Edit_Mosaic = len(ed.mosaic.colors) > 0 ? &ed.mosaic : nil
	paint := Edit_Paint{doc = &m.doc, picture = ed.tex, mosaic = mosaic, font_id = app.shared.font, fonts = &app.shared.fonts,
		zoom = m.view.zoom, origin = m.view.canvas.min + m.view.offset, skip = skip}
	draw.push_clip(dc, b.rect)
	edit_paint(dc, &paint)
	canvas_crop(dc, m)
	canvas_selection(dc, m, ed.accent, ed.scale)
	draw.pop_clip(dc)
	edit_export_record(dc, &ed.export, paint)
}

// Outside the crop, darker; the crop's edge, white.
@(private = "file")
canvas_crop :: proc(dc: ^draw.Context, m: ^Edit_Model) {
	if !m.doc.has_crop { return }
	pic := draw.Rect{edit_to_window(m.view, {0, 0}), edit_to_window(m.view, m.doc.size)}
	c := draw.Rect{edit_to_window(m.view, m.doc.crop.min), edit_to_window(m.view, m.doc.crop.max)}
	dim := draw.Color{0, 0, 0, EDITOR_CROP_DIM}
	draw.rect(dc, {pic.min, {pic.max.x, c.min.y}}, dim)
	draw.rect(dc, {{pic.min.x, c.max.y}, pic.max}, dim)
	draw.rect(dc, {{pic.min.x, c.min.y}, {c.min.x, c.max.y}}, dim)
	draw.rect(dc, {{c.max.x, c.min.y}, {pic.max.x, c.max.y}}, dim)
	draw.rect(dc, draw.rect_pad(c, 1), {1, 1, 1, 0.9}, 0, 1)
}

// The selected shape's frame and handles.
@(private = "file")
canvas_selection :: proc(dc: ^draw.Context, m: ^Edit_Model, accent: draw.Color, scale: f32) {
	s := edit_selected_shape(m)
	if s == nil { return }
	if _, typing := m.mode.(Edit_Typing); typing { return }
	px := max(math.round(scale), 1)
	at, has := edit_handles(&m.doc, s)
	if has == {} || s.kind == .Rectangle || s.kind == .Ellipse || s.kind == .Highlighter || s.kind == .Pixelate {
		r := edit_shape_box(&m.doc, s)
		pad := edit_stroke_px(&m.doc, s) * 0.5 * m.view.zoom + 3
		box := draw.rect_pad(draw.Rect{edit_to_window(m.view, r.min), edit_to_window(m.view, r.max)}, pad)
		draw.rect(dc, box, accent, 0, px)
	}
	half := f32(EDITOR_HANDLE_SIDE) * 0.5 * scale
	for h in Edit_Handle {
		if h not_in has { continue }
		c := edit_to_window(m.view, at[h])
		draw.rect(dc, {c - half, c + half}, {1, 1, 1, 1}, 1.5)
		draw.rect(dc, {c - half, c + half}, accent, 1.5, px)
	}
}

// An editor's Ctrl+C, its PNG made on the worker: on the clipboard (the anchor's, as a workflow's Copy step: it outlives
// the editor's window), and said in that editor while it is shown. A copy asked before its editor closed still goes
// on the clipboard: the person asked for it.
editor_copied :: proc(app: ^App, r: Result_Copy_Encoded) {
	r := r
	defer { shot_free(&r.shot); delete(r.png) }
	ok := len(r.png) > 0 && platform.clipboard_set_image(app.anchor, {rgba = r.shot.rgba, size = r.shot.size, png = r.png})
	window := editor_window(app, r.editor)
	if ok { app_announce(app, .Good, i18n.tr("Copied to the clipboard"), "", window) } else { app_announce(app, .Bad, i18n.tr("The picture cannot go to the clipboard"), "", window) }
}

////////////////////////////////
// The last choices: the tool and each tool's style, kept in the preferences (editor.tool, editor.styles) when an editor's
// picture goes, and given to the next editor. A style reads "<tool> <rrggbb> <width> <shadow's softness> <fill> <text size>", one per
// tool, separated by ";".

// The model given the choices kept; what is not there, or not read, stays the default.
editor_choices_load :: proc(app: ^App, m: ^Edit_Model) {
	edit_choices_read(m, config.string_of(&app.prefs, "editor.tool"), config.string_of(&app.prefs, "editor.styles"))
}

// The model's tool and styles in the preferences, when they changed (written by the worker: app_prefs_changed).
editor_choices_keep :: proc(app: ^App, m: ^Edit_Model) {
	if !app.worker.started { return }   // (an editor of clichetool shots: the user's preferences are not its)
	tool, styles := edit_choices_text(m)
	if tool == config.string_of(&app.prefs, "editor.tool") && styles == config.string_of(&app.prefs, "editor.styles") { return }
	config.set_from_string(&app.prefs, "editor.tool", tool, .User)
	config.set_from_string(&app.prefs, "editor.styles", styles, .User)
	app_prefs_changed(app)
}

// The tool and the styles of `m` as editor.tool and editor.styles say them. Temp allocator.
edit_choices_text :: proc(m: ^Edit_Model) -> (tool, styles: string) {
	b := strings.builder_make(context.temp_allocator)
	for t in Edit_Tool {
		s := m.styles[t]
		if t != .Select { strings.write_string(&b, ";") }
		fmt.sbprintf(&b, "%v %06x %g %g %d %g", t, s.color, s.width, s.shadow, s.fill ? 1 : 0, s.text_size)
	}
	return fmt.tprintf("%v", m.tool), strings.to_string(b)
}

// `m` given the tool and the styles that editor.tool and editor.styles say; a part not read is left as it is.
edit_choices_read :: proc(m: ^Edit_Model, tool, styles: string) {
	if t, ok := edit_tool_named(tool); ok { m.tool = t }
	rest := styles
	for part in strings.split_iterator(&rest, ";") {
		f := strings.fields(part, context.temp_allocator)
		if len(f) != 6 { continue }
		t, known := edit_tool_named(f[0])
		color, c_ok := strconv.parse_u64_of_base(f[1], 16)
		width, w_ok := strconv.parse_f32(f[2])
		shadow, sh_ok := strconv.parse_f32(f[3])
		size, s_ok := strconv.parse_f32(f[5])
		if !known || !c_ok || !w_ok || !sh_ok || !s_ok || color > 0xFFFFFF || size <= 0 { continue }
		m.styles[t] = {color = u32(color), width = clamp(width, EDIT_WIDTH_MIN, EDIT_WIDTH_MAX), shadow = clamp(shadow, 0, EDIT_SHADOW_MAX), fill = f[4] == "1", text_size = size}
	}
}

@(private = "file")
edit_tool_named :: proc(name: string) -> (Edit_Tool, bool) {
	for t in Edit_Tool { if fmt.tprintf("%v", t) == name { return t, true } }
	return {}, false
}
