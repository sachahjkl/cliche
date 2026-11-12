package cliche

// The editor: a window of its own where a picture just taken gets arrows, boxes, text and the rest before the
// after-capture chain runs on it. Every annotation stays an object (editor_model.odin) until the picture is done: it is
// selected, moved, resized, recoloured or deleted, and every change is undone and redone.
//
// The window follows the settings' model (settings_view.odin): a host of its own, opened at the first picture and then
// hidden, not closed; the theme of appearance.theme; the command palette (Ctrl+K) and the sheet of its keys (F1).
//
//   the bar      the tools (each an icon, a tooltip and a key), the properties of the tool or of the selection, then
//                undo, redo, copy, save and Done
//   the canvas   the picture and its shapes (editor_export.odin paints them), the selection's handles, the crop
//
// The canvas takes the pointer itself (editor_input: its presses, releases and wheel never reach the widgets) and turns
// it into the model's events; the keys go through the commands' table, as the settings' do. A text being typed is a
// field of the toolkit's over the canvas.
//
// Done hands the flattened picture to the after-capture chain (app_chain_run); a close without Done gives the capture
// up (Flow_Cancelled). Flattening runs on the GPU (an offscreen target read back a frame later); the PNG is encoded and
// written on the worker (Job_Save), as always. A file of the history is read and decoded on a thread of the editor's.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import "core:strings"
import "gt:draw"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import png "gt:png"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"

EDITOR_SIZE :: [2]int{1180, 780}
EDITOR_DOUBLE_CLICK_MS :: 450
EDITOR_DOUBLE_CLICK_PX :: 5
EDITOR_HANDLE_SIDE :: 8     // a handle's side, logical pixels
EDITOR_CROP_DIM :: 0.55     // how dark the picture is outside the crop

// Lucide's icons that gt:lucide has no name for yet: the font's code points, under Lucide's names. (They belong in
// gt:lucide; they are here until the toolkit names them.)
@(private = "file") ICON_POINTER     :: ""   // mouse-pointer-2
@(private = "file") ICON_CIRCLE      :: ""   // circle
@(private = "file") ICON_ARROW       :: ""   // arrow-up-right
@(private = "file") ICON_LINE        :: ""   // slash
@(private = "file") ICON_HIGHLIGHTER :: ""   // highlighter
@(private = "file") ICON_PIXELATE    :: ""   // layout-grid
@(private = "file") ICON_STEP        :: ""   // list-ordered
@(private = "file") ICON_CROP        :: ""   // crop
@(private = "file") ICON_FIT         :: ""   // maximize

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
	.Tool_Select      = {label = "Select and move", group = "Tools", keys = {{.V, {}}, {}}, icon = ICON_POINTER, tags = {"pointer", "move", "resize"}},
	.Tool_Rectangle   = {label = "Rectangle", group = "Tools", keys = {{.R, {}}, {}}, icon = lucide.SQUARE, tags = {"box", "square", "frame"}},
	.Tool_Ellipse     = {label = "Ellipse", group = "Tools", keys = {{.E, {}}, {}}, icon = ICON_CIRCLE, tags = {"circle", "oval", "round"}},
	.Tool_Arrow       = {label = "Arrow", group = "Tools", keys = {{.A, {}}, {}}, icon = ICON_ARROW, tags = {"point", "show"}},
	.Tool_Line        = {label = "Line", group = "Tools", keys = {{.L, {}}, {}}, icon = ICON_LINE, tags = {"straight", "rule"}},
	.Tool_Pen         = {label = "Pen", group = "Tools", keys = {{.P, {}}, {}}, icon = lucide.PENCIL, tags = {"freehand", "draw", "brush"}},
	.Tool_Text        = {label = "Text", group = "Tools", keys = {{.T, {}}, {}}, icon = lucide.TYPE, tags = {"label", "write", "words"}},
	.Tool_Highlighter = {label = "Highlighter", group = "Tools", keys = {{.H, {}}, {}}, icon = ICON_HIGHLIGHTER, tags = {"marker", "yellow", "emphasis"}},
	.Tool_Pixelate    = {label = "Pixelate", group = "Tools", keys = {{.B, {}}, {}}, icon = ICON_PIXELATE, tags = {"blur", "hide", "censor", "mosaic", "redact"}},
	.Tool_Step        = {label = "Step number", group = "Tools", keys = {{.N, {}}, {}}, icon = ICON_STEP, tags = {"counter", "badge", "numbered"}},
	.Tool_Crop        = {label = "Crop", group = "Tools", keys = {{.C, {}}, {}}, icon = ICON_CROP, tags = {"cut", "trim"}},
	.Undo             = {label = "Undo", group = "Edit", keys = {{.Z, {.Ctrl}}, {}}, icon = lucide.UNDO_2, tags = {"back", "revert"}},
	.Redo             = {label = "Redo", group = "Edit", keys = {{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}}}, icon = lucide.REDO_2, tags = {"again", "forward"}},
	.Delete           = {label = "Delete the selection", group = "Edit", keys = {{.Delete, {}}, {.Backspace, {}}}, icon = lucide.TRASH_2, tags = {"remove", "erase"}},
	.Duplicate        = {label = "Duplicate the selection", group = "Edit", keys = {{.D, {.Ctrl}}, {}}, icon = lucide.COPY, tags = {"clone", "copy"}},
	.Remove_Crop      = {label = "Remove the crop", group = "Edit", icon = ICON_CROP, tags = {"uncrop", "whole", "reset"}},
	.Zoom_In          = {label = "Zoom in", group = "View", keys = {{.Equal, {.Ctrl}}, {.Num_Add, {.Ctrl}}}, icon = lucide.ZOOM_IN, tags = {"larger", "magnify"}},
	.Zoom_Out         = {label = "Zoom out", group = "View", keys = {{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}, icon = lucide.ZOOM_OUT, tags = {"smaller"}},
	.Zoom_Fit         = {label = "Fit the picture to the window", group = "View", keys = {{.N0, {.Ctrl}}, {}}, icon = ICON_FIT, tags = {"zoom", "whole", "reset"}},
	.Copy             = {label = "Copy the picture", group = "Picture", keys = {{.C, {.Ctrl}}, {}}, icon = lucide.CLIPBOARD_COPY, tags = {"clipboard"}},
	.Save             = {label = "Save the picture", group = "Picture", keys = {{.S, {.Ctrl}}, {}}, icon = lucide.SAVE, tags = {"file", "png", "write"}},
	.Done             = {label = "Done: run the after-capture actions", group = "Picture", keys = {{.Return, {}}, {}}, icon = lucide.CHECK, tags = {"finish", "apply", "upload", "ok"}},
	.Close            = {label = "Close the editor", group = "Window", keys = {{.W, {.Ctrl}}, {}}, icon = lucide.X, tags = {"discard", "cancel", "quit"}},
	.Palette          = {label = "Command palette", group = "Window", keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND, tags = {"actions", "search"}},
	.Keys             = {label = "Keyboard shortcuts", group = "Window", keys = {{.F1, {}}, {}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}},
	.Nudge            = {label = "Move the selection a pixel (arrows; with Shift, ten)", group = "Edit", keys = {{.Left, {}}, {.Left, {.Shift}}}, icon = ICON_POINTER, tags = {"nudge"}},
}

@(rodata)
EDITOR_COLOR_NAMES := [len(EDIT_COLORS)]string{"Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"}

// The mosaic of a picture, made on a thread of its own (it reads every pixel). The thread owns this until `done`.
Editor_Mosaic_Work :: struct {
	rgba:   []u8,   // the editor's picture, read only
	size:   [2]int,
	cell:   int,
	out:    Edit_Mosaic,
	cancel: bool,   // atomic: the picture goes, the thread stops early
	done:   bool,   // atomic
	app:    ^App,
}

// A PNG file read and decoded on a thread of its own (editor_open_file). The thread owns this until `done`.
Editor_Load_Work :: struct {
	path: string,   // owned
	rgba: []u8,     // owned once read
	size: [2]int,
	ok:   bool,
	done: bool,     // atomic
	app:  ^App,
}

Editor :: struct {
	host:        host.Host,
	opened:      bool,
	visible:     bool,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	palette:     ui.Command_Palette,
	sheet_open:  bool,
	width_field: ui.Slider_Field,   // the bar's width: its slider's field
	asking:      bool,       // the question before the changes are dropped
	close_due:   bool,       // closed in a frame: acted on after it (editor_after_frame)

	model:       Edit_Model,
	has_picture: bool,
	shot:        Shot,       // the picture as taken (owned while has_picture)
	tex:         render.Texture,
	tex_size:    [2]int,
	mosaic:      Edit_Mosaic,
	mosaic_work: ^Editor_Mosaic_Work,
	mosaic_thread: ^thread.Thread,
	load_work:   ^Editor_Load_Work,   // a file being read (editor_open_file)
	load_thread: ^thread.Thread,
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

// Shows `shot` (taken: the editor owns it now) in the editor. `scale`: the picture's pixels per logical pixel (2 for a
// picture of a screen at 200 %). False: no window could open; the shot is freed.
editor_open_shot :: proc(app: ^App, shot: Shot, scale: f32 = 1) -> bool {
	ed := &app.editor
	shot := shot
	timing_mark("editor asked")
	if !ed.opened && !editor_open(app, headless = false) {
		shot_free(&shot)
		return false
	}
	timing_mark("editor window open")
	editor_picture_drop(app)
	editor_load_stop(app)
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
		fmt.eprintln("cliche: the editor cannot hold the picture")
		shot_free(&shot)
		return false
	}
	// (mips: a picture shown smaller than its pixels stays sharp, not grainy)
	render.update_texture_rgba(r, ed.tex, 0, 0, w, h, shot.rgba)
	timing_mark("picture uploaded")
	ed.shot, ed.has_picture = shot, true
	edit_model_init(&ed.model, shot.size, scale, editor_measure, app)
	ed.field_typing = 0
	ed.asking, ed.close_due, ed.exporting = false, false, false
	editor_mosaic_start(app, int(math.round(EDIT_PIXELATE_CELL * ed.model.doc.scale)))
	token := app_take_token(app)
	defer delete(token)
	if !ed.visible {
		host.host_show(&ed.host)
		ed.visible = true
	}
	platform.raise_window_token(ed.host.win, token)
	ed.host.settle = max(ed.host.settle, 3)
	timing_mark("editor shown")
	return true
}

// Shows the editor with the PNG file at `path` (not kept), read and decoded on a thread of the editor's: the window
// says so meanwhile, and says why when the file cannot be read.
editor_open_file :: proc(app: ^App, path: string) {
	ed := &app.editor
	if !ed.opened && !editor_open(app, headless = false) { return }
	if ed.has_picture && edit_changed(&ed.model) {
		// (a picture with changes is not dropped for another)
		platform.raise_window_token(ed.host.win, "")
		return
	}
	editor_picture_drop(app)
	editor_load_stop(app)
	ed.load_problem = ""
	work := new(Editor_Load_Work)
	work^ = {path = strings.clone(path), app = app}
	t := thread.create(proc(t: ^thread.Thread) {
		work := (^Editor_Load_Work)(t.data)
		if data, err := os.read_entire_file(work.path, context.allocator); err == nil {
			rgba, w, h, ok := png.decode(data)
			delete(data)
			if ok { work.rgba, work.size, work.ok = rgba, {w, h}, true }
		}
		free_all(context.temp_allocator)
		sync.atomic_store(&work.done, true)
		app_wake(work.app)
	})
	if t == nil {
		delete(work.path)
		free(work)
		ed.load_problem = "The picture cannot be read."
	} else {
		t.data = work
		ed.load_work, ed.load_thread = work, t
		thread.start(t)
	}
	token := app_take_token(app)
	defer delete(token)
	if !ed.visible {
		host.host_show(&ed.host)
		ed.visible = true
	}
	platform.raise_window_token(ed.host.win, token)
	ed.host.settle = max(ed.host.settle, 3)
}

// Opens the window (hidden). `headless`: offscreen, on the software renderer (shots, tests).
editor_open :: proc(app: ^App, headless: bool) -> bool {
	ed := &app.editor
	if !host.host_open(&ed.host, &app.shared, {title = "cliche editor", size = EDITOR_SIZE, headless = headless}, editor_build, app) {
		fmt.eprintln("cliche: the editor's window cannot open")
		return false
	}
	ed.opened = true
	ed.host.input = editor_input
	ed.host.params = editor_params
	ed.host.after_input = 3
	ed.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	ed.host.state.icon_font = ed.icons
	app_wake_set(app, .Editor, ed.host.win)
	return true
}

// After a frame of the editor: a file read, the mosaic made, the flattened picture read, a close acted on.
editor_after_frame :: proc(app: ^App) {
	ed := &app.editor
	editor_load_take(app)
	editor_mosaic_take(app)
	if ed.exporting { editor_export_poll(app) }
	if ed.close_due {
		ed.close_due = false
		editor_close(app)   // (the picture goes: nothing is copied, saved or told; the capture's flow was over already)
	}
}

// The file, once its thread is done: shown, or why not.
@(private = "file")
editor_load_take :: proc(app: ^App) {
	ed := &app.editor
	work := ed.load_work
	if work == nil || !sync.atomic_load(&work.done) { return }
	thread.join(ed.load_thread)
	thread.destroy(ed.load_thread)
	ed.load_work, ed.load_thread = nil, nil
	delete(work.path)
	ok, rgba, size := work.ok, work.rgba, work.size
	free(work)
	if !ok {
		ed.load_problem = "The picture cannot be read: it is not a PNG file, or it is gone."
		ed.host.settle = max(ed.host.settle, 2)
		return
	}
	editor_open_shot(app, {rgba = rgba, size = size, source = .Region})
}

// Before the window closes for good: a file being read is waited for, then dropped.
@(private = "file")
editor_load_stop :: proc(app: ^App) {
	ed := &app.editor
	if ed.load_thread == nil { return }
	thread.join(ed.load_thread)
	thread.destroy(ed.load_thread)
	delete(ed.load_work.path)
	delete(ed.load_work.rgba)
	free(ed.load_work)
	ed.load_work, ed.load_thread = nil, nil
}

// What the worker said of a save asked from the editor (Ctrl+S): told in the window. `path` is not kept.
editor_saved :: proc(app: ^App, path: string, error: Flow_Error) {
	ed := &app.editor
	if !ed.visible { return }
	ui.use(&ed.host.state)
	defer ui.use(&app.shared.main.state)
	if error != .None { ui.toast(.Bad, "%s", FLOW_ERROR_TEXT[error]) } else { ui.toast(.Good, "Saved: %s", path) }
	ed.host.settle = max(ed.host.settle, 3)
}

// The texture goes with the renderer: before the windows close.
editor_destroy :: proc(app: ^App) {
	ed := &app.editor
	editor_picture_drop(app)
	if ed.tex != 0 { render.destroy_texture(&app.shared.r, ed.tex) }
	ed.tex = 0
}

editor_free :: proc(app: ^App) {
	ed := &app.editor
	editor_load_stop(app)
	editor_picture_drop(app)
	ui.palette_destroy(&ed.palette)
	ui.field_destroy(&ed.field)
	ui.slider_field_destroy(&ed.width_field)
}

// The window hidden, the picture and its shapes let go.
@(private = "file")
editor_close :: proc(app: ^App) {
	ed := &app.editor
	ed.palette.open = false
	ed.sheet_open = false
	ed.asking = false
	if ed.visible {
		host.host_hide(&ed.host)
		ed.visible = false
	}
	editor_picture_drop(app)
}

@(private = "file")
editor_picture_drop :: proc(app: ^App) {
	ed := &app.editor
	editor_mosaic_stop(app)
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
// The mosaic's thread

@(private = "file")
editor_mosaic_start :: proc(app: ^App, cell: int) {
	ed := &app.editor
	work := new(Editor_Mosaic_Work)
	work^ = {rgba = ed.shot.rgba, size = ed.shot.size, cell = cell, app = app}
	t := thread.create(proc(t: ^thread.Thread) {
		work := (^Editor_Mosaic_Work)(t.data)
		work.out = edit_mosaic_make(work.rgba, work.size, work.cell, &work.cancel)
		free_all(context.temp_allocator)
		sync.atomic_store(&work.done, true)
		app_wake(work.app)
	})
	if t == nil {
		free(work)
		return   // (no thread: a pixelated box stays grey)
	}
	t.data = work
	ed.mosaic_work, ed.mosaic_thread = work, t
	thread.start(t)
}

// The mosaic, once its thread is done.
@(private = "file")
editor_mosaic_take :: proc(app: ^App) {
	ed := &app.editor
	if ed.mosaic_work == nil || !sync.atomic_load(&ed.mosaic_work.done) { return }
	thread.join(ed.mosaic_thread)
	thread.destroy(ed.mosaic_thread)
	edit_mosaic_free(&ed.mosaic)
	ed.mosaic = ed.mosaic_work.out
	free(ed.mosaic_work)
	ed.mosaic_work, ed.mosaic_thread = nil, nil
	ed.host.settle = max(ed.host.settle, 1)
}

// Before the picture goes: the thread reads it. Told to stop, it ends within a row of cells.
@(private = "file")
editor_mosaic_stop :: proc(app: ^App) {
	ed := &app.editor
	if ed.mosaic_thread == nil { return }
	sync.atomic_store(&ed.mosaic_work.cancel, true)
	thread.join(ed.mosaic_thread)
	thread.destroy(ed.mosaic_thread)
	edit_mosaic_free(&ed.mosaic_work.out)
	free(ed.mosaic_work)
	ed.mosaic_work, ed.mosaic_thread = nil, nil
}

////////////////////////////////
// Input

// Each build: the theme, as the main window has it.
@(private = "file")
editor_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	ed := &app.editor
	a := app.settings.appearance
	choice := prefs_page.appearance_choice(a)
	choice.glow = 1
	if ui.theme_show(&app.shared.theme, themes(), choice, &ed.theme_shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !ed.theme_shown.light)
	}
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
}

// The canvas' pointer goes to the model; the rest to the widgets. A press is the canvas' when it lands on it with no
// dialog or menu open, and not on the text field; a release, a move or the wheel when a gesture goes on.
@(private = "file")
editor_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	app := (^App)(h.user)
	ed := &app.editor
	m := &ed.model
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	if !ed.has_picture {
		// (a file being read, or one that could not be: the window's close still closes it)
		for e in events {
			if e.kind == .Close { platform.cancel_close(h.win); ed.close_due = true; continue }
			append(&out, e)
		}
		return out[:]
	}
	blocked := ed.palette.open || ed.sheet_open || ed.asking || ed.exporting || ui.ctx_menu_any_open()
	_, typing := m.mode.(Edit_Typing)
	for e in events {
		#partial switch e.kind {
		case .Close:
			platform.cancel_close(h.win)
			editor_close_asked(app)
			continue
		case .Key_Press:
			if e.key == .Space && !typing && !blocked && !e.repeat { ed.space = true }
		case .Key_Release:
			if e.key == .Space { ed.space = false }
		case .Mouse_Move:
			ed.pointer, ed.has_pointer = e.pos, true
			if !edit_idle(m) && !typing { edit_step(m, Edit_Move{at = e.pos, shift = .Shift in e.mods}) }
			editor_hover(app)
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
			editor_hover(app)
			continue
		case .Mouse_Release:
			if edit_idle(m) || typing { break }
			button := Edit_Button.Left
			if e.button == .Middle { button = .Middle } else if e.button == .Right { button = .Right }
			edit_step(m, Edit_Release{at = e.pos, button = button, shift = .Shift in e.mods})
			editor_hover(app)
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
editor_hover :: proc(app: ^App) {
	ed := &app.editor
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
editor_action_enabled :: proc(app: ^App, a: Editor_Action) -> bool {
	ed := &app.editor
	m := &ed.model
	if !ed.has_picture || ed.exporting { return a == .Close || a == .Palette || a == .Keys }
	#partial switch a {
	case .Undo:                         return edit_can_undo(m)
	case .Redo:                         return edit_can_redo(m)
	case .Delete, .Duplicate, .Nudge:   return edit_idle(m) && edit_has_selection(m)
	case .Remove_Crop:                  return edit_idle(m) && m.doc.has_crop
	}
	return true
}

@(private = "file")
editor_action :: proc(app: ^App, a: Editor_Action) {
	ed := &app.editor
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
	case .Copy:        editor_export_start(app, .Copy)
	case .Save:        editor_export_start(app, .Save)
	case .Done:        editor_export_start(app, .Done)
	case .Close:       editor_close_asked(app)
	case .Palette:     ui.palette_open(&ed.palette)
	case .Keys:        ed.sheet_open = true
	case .Nudge:       edit_nudge(m, {1, 0})
	}
	editor_hover(app)
}

// A close asked (the window's button, Escape, Ctrl+W): at once with nothing changed, else after the question.
editor_close_asked :: proc(app: ^App) {
	ed := &app.editor
	if ed.exporting { return }
	if ed.has_picture && edit_changed(&ed.model) { ed.asking = true } else { ed.close_due = true }
}

// The picture flattened for `purpose`. A text being typed is kept first. Done with nothing changed hands the picture as
// it was taken: nothing to draw.
@(private = "file")
editor_export_start :: proc(app: ^App, purpose: Edit_Export_Purpose) {
	ed := &app.editor
	m := &ed.model
	if !ed.has_picture || ed.exporting { return }
	if _, typing := m.mode.(Edit_Typing); typing { edit_step(m, Edit_Type_End{keep = true}) }
	if !edit_idle(m) { return }
	if purpose == .Done && !edit_changed(m) {
		shot := ed.shot
		ed.shot, ed.has_picture = {}, false
		edit_model_destroy(&ed.model)
		editor_close(app)
		app_chain_run(app, shot, edited = true)
		return
	}
	edit_export_begin(&ed.export, purpose, &m.doc)
	ed.exporting = true
	ed.host.settle = max(ed.host.settle, 2)
}

// The flattened picture, once read back: to the chain, the clipboard or a file.
@(private = "file")
editor_export_poll :: proc(app: ^App) {
	ed := &app.editor
	shot, status := edit_export_poll(&app.shared.r, &ed.export, ed.shot.source)
	switch status {
	case .Pending, .None:
		ed.host.settle = max(ed.host.settle, 2)   // (frames go on until the copy is read)
		return
	case .Failed:
		purpose := ed.export.purpose
		edit_export_free(&ed.export)
		ed.exporting = false
		ui.use(&ed.host.state)
		defer ui.use(&app.shared.main.state)
		ui.toast(.Bad, "The picture could not be made%s", purpose == .Done ? ": nothing was done with it" : "")
		ed.host.settle = max(ed.host.settle, 3)
		return
	case .Ready:
	}
	purpose := ed.export.purpose
	edit_export_free(&ed.export)
	ed.exporting = false
	switch purpose {
	case .Done:
		editor_close(app)
		app_chain_run(app, shot, edited = true)
	case .Copy:
		// (the clipboard is the anchor's, as the chain's copy is: it outlives this window)
		ok := platform.clipboard_set_image(app.anchor, {rgba = shot.rgba, size = shot.size})
		shot_free(&shot)
		ui.use(&ed.host.state)
		defer ui.use(&app.shared.main.state)
		if ok { ui.toast(.Good, "Copied to the clipboard") } else { ui.toast(.Bad, "The picture cannot go to the clipboard") }
		ed.host.settle = max(ed.host.settle, 3)
	case .Save:
		worker_send(&app.worker, Job_Save{
			shot = shot, folder = strings.clone(app.settings.folder), pattern = strings.clone(app.settings.name_pattern),
			save = true, fast = app.settings.fast_png, reveal = app.settings.reveal, from_editor = true,
		})
	}
}

////////////////////////////////
// The window's interface

@(private = "file")
editor_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	ed := &app.editor
	em := ui.font_size()
	if !ed.has_picture {
		editor_waiting(app, em)
		return
	}
	m := &ed.model
	ed.accent, ed.scale = ui.color("accent"), ui.scale()

	// (while a text is typed, its field has the keys: no command takes a letter from it)
	_, typing := m.mode.(Edit_Typing)
	dialog := ed.palette.open || ed.sheet_open || ed.asking
	if !dialog && !typing && !ed.exporting {
		if ui.key_press(.Escape) {
			if !edit_deselect(m) { editor_close_asked(app) }
		}
		editor_nudge_keys(app)
		for a in Editor_Action {
			if a == .Nudge { continue }
			if ui.command_pressed(EDITOR_ACTIONS[a], editor_action_enabled(app, a)) { editor_action(app, a); break }
		}
	}

	canvas: ui.Rect
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(flags = {.Draw_Background}, id = "###editor") {   // (the theme's surface: the host only clears to black)
		editor_bar(app, em)
		ui.next({width = ui.fill(), height = ui.fill(), cursor = ed.hover, bg = ui.color("well")})
		b := ui.build_box({.Clickable, .Clip, .Draw_Background}, "###canvas")
		b.custom, b.custom_user = editor_canvas_draw, app
		_ = ui.signal(b)
		canvas = b.rect   // (last frame's layout: where the canvas is)
	}
	// (after the canvas: drawn over it, and first for the pointer)
	editor_text_field(app, em)
	editor_dialogs(app)
	// (the toasts at the bottom of the canvas: over the bar they hid the buttons just pressed)
	if canvas.max.x > canvas.min.x { ui.set_toast_area(canvas) }
	ui.set_toast_position(&ed.host.state, .Bottom_Center)
	ui.toasts_build()
}

// No picture yet: a file is read, or could not be. Escape closes.
@(private = "file")
editor_waiting :: proc(app: ^App, em: f32) {
	ed := &app.editor
	if ui.key_press(.Escape) || ui.command_pressed(EDITOR_ACTIONS[.Close]) { ed.close_due = true }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, cross = .Center})
	if ui.column(id = "###waiting") {
		ui.spacer(ui.pct(0.4))
		text := ed.load_problem != "" ? ed.load_problem : "Reading the picture…"
		if ui.tags(ed.load_problem != "" ? "bad" : "weak") {
			ui.next({width = ui.text_size(em), height = ui.px(em * 2)})
			ui.label(fmt.tprintf("%s###waiting_text", text))
		}
	}
}

@(private = "file")
editor_nudge_keys :: proc(app: ^App) {
	m := &app.editor.model
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
editor_text_field :: proc(app: ^App, em: f32) {
	ed := &app.editor
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
	res := ui.line_edit("###edit_text", &ed.field, placeholder = "Text", menu = false)
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
editor_bar :: proc(app: ^App, em: f32) {
	ed := &app.editor
	m := &ed.model
	side := math.round(em * 2.2)
	ui.next({width = ui.fill(), height = ui.px(side + math.round(em * 0.8)), axis = .X, cross = .Center})
	if ui.row(id = "###bar") {
		ui.spacer(ui.px(em * 0.5))
		for t in Edit_Tool {
			a := Editor_Action(int(Editor_Action.Tool_Select) + int(t))
			if bar_icon(fmt.tprintf("tool%d", int(t)), EDITOR_ACTIONS[a], side, active = m.tool == t, enabled = true) { editor_action(app, a) }
		}
		bar_separator(em, side)
		editor_properties(app, em, side)
		ui.spacer(ui.fill())
		for a in ([?]Editor_Action{.Undo, .Redo, .Copy, .Save}) {
			if bar_icon(fmt.tprintf("act%d", int(a)), EDITOR_ACTIONS[a], side, active = false, enabled = editor_action_enabled(app, a)) { editor_action(app, a) }
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.text_size(em * 1.2), height = ui.px(side), radius = em * 0.4})
		sig: ui.Signal
		if ui.tags("accent_button") { sig = ui.button("Done###done") }
		if sig.clicked && editor_action_enabled(app, .Done) { editor_action(app, .Done) }
		if ui.hovered_for(sig, 0.4) { if ui.tooltip() { ui.tooltip_text(ui.command_tip(EDITOR_ACTIONS[.Done])) } }
		ui.spacer(ui.px(em * 0.5))
	}
}

// The properties of the selection, else of the tool: what applies to its kind only.
@(private = "file")
editor_properties :: proc(app: ^App, em: f32, side: f32) {
	m := &app.editor.model
	style, props := edit_style_shown(m)
	if props == {} { return }
	before := style
	if .Color in props {
		for c, i in EDIT_COLORS {
			if swatch(fmt.tprintf("swatch%d", i), c, EDITOR_COLOR_NAMES[i], style.color == c, math.round(side * 0.62)) { style.color = c }
			ui.spacer(ui.px(math.round(em * 0.25)))
		}
		bar_separator(em, side)
	}
	if .Width in props {
		// (a slider for the feel, its field for the exact width)
		ui.next({width = ui.px(math.round(em * 13)), height = ui.px(math.round(side * 0.85))})
		ui.slider_field("###width", &app.editor.width_field, &style.width, EDIT_WIDTH_MIN, EDIT_WIDTH_MAX, 1, unit = "px")
		ui.spacer(ui.px(em * 0.5))
	}
	if .Text_Size in props {
		@(static, rodata) labels := [len(EDIT_TEXT_SIZES)]string{"S", "M", "L", "XL"}
		@(static, rodata) tips := [len(EDIT_TEXT_SIZES)]string{"Small text", "Medium text", "Large text", "Very large text"}
		at := 0
		for v, i in EDIT_TEXT_SIZES { if v == style.text_size { at = i } }
		ui.next({width = ui.px(em * 10), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###text_size", labels[:], &at, tips[:]) { style.text_size = EDIT_TEXT_SIZES[at] }
		ui.spacer(ui.px(em * 0.5))
	}
	if .Shadow in props {
		ui.next({height = ui.px(side)})
		ui.toggle("###shadow", "Shadow", &style.shadow)
		ui.spacer(ui.px(em * 0.4))
	}
	if .Fill in props {
		ui.next({height = ui.px(side)})
		ui.toggle("###fill", "Fill", &style.fill)
	}
	if style != before { edit_style_set(m, style) }
}

// An icon of the bar: its command's tooltip; `active`: the tool in use.
@(private = "file")
bar_icon :: proc(id: string, c: ui.Command, side: f32, active, enabled: bool) -> bool {
	mod := ui.Style_Mod{width = ui.px(side), height = ui.px(side), radius = math.round(side * 0.22), font_size = math.round(side * 0.5)}
	if active {
		bg := ui.color("accent")
		bg.a *= 0.28
		mod.bg = bg
	}
	if !enabled { mod.flags = {.Disabled} }
	ui.next(mod)
	sig := ui.icon_button(id, c.icon)
	if ui.hovered_for(sig, 0.4) { if ui.tooltip() { ui.tooltip_text(ui.command_tip(c)) } }
	return enabled && sig.clicked
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
	if ui.hovered_for(sig, 0.4) { if ui.tooltip() { ui.tooltip_text(name) } }
	return sig.clicked
}

// The palette (every action but the arrows), the sheet of keys, the question before the changes are dropped.
@(private = "file")
editor_dialogs :: proc(app: ^App) {
	ed := &app.editor
	all := slice.enumerated_array(&EDITOR_ACTIONS)
	if ed.palette.open {
		listed := all[:len(all) - 1]   // (Nudge: its keys are the arrows)
		enabled := make([]bool, len(listed), context.temp_allocator)
		for i in 0 ..< len(listed) { enabled[i] = editor_action_enabled(app, Editor_Action(i)) }
		if i, _ := ui.palette(&ed.palette, listed, enabled); i >= 0 { editor_action(app, Editor_Action(i)) }
	}
	ui.shortcuts_sheet("keys", all, &ed.sheet_open, "The editor's keys")
	switch ui.confirm("drop", &ed.asking, {title = "Close the editor and drop the changes?", note = "The annotations on this picture are lost. Nothing is copied or saved.", act = "Drop the changes"}) {
	case .Confirmed: ed.close_due = true
	case .Cancelled, .None:
	}
}

////////////////////////////////
// The canvas

// The canvas' draw: the picture and its shapes, the crop, the selection's handles; then the export, when one is due.
@(private = "file")
editor_canvas_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	ed := &app.editor
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
