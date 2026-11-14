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
// multi-line field of the toolkit's over the canvas (Enter ends it, Shift+Enter breaks the line). A right press on a
// shape opens its menu (delete, duplicate, its place among the others).
//
// What reads every pixel runs on the chores: each mosaic (Pixelate) and blurred copy (Blur) the shapes or the tool need,
// once per picture and size (Editor_Filter); the decoding of a picture pasted. Ctrl+V asks the clipboard without waiting
// (platform.clipboard_request): a picture first, else a text (Editor_Paste, one state machine).
//
// Done hands the flattened picture back to the run that asked for it (workflow_editor_done); a picture of the history
// runs the workflow of "Capture a region and edit". Cancel, or a close without Done, cancels the run's Annotate step
// (workflow_editor_closed): what needs its picture or its "done" is skipped, what hangs on its "cancelled" runs. Flattening runs on the GPU (an offscreen target read back a frame later); Ctrl+S encodes and
// writes the PNG on the worker (Job_Save). Save as, Upload and Print are editor_output.odin's, Pin pin.odin's. A file
// (of the history, or dropped on the window: PNG, JPEG, WebP, BMP) is read and decoded by a task of the chores; each
// file dropped opens in an editor of its own, after the frame.

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
import pic "gt:image"
import "gt:platform"
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
	Tool_Pixelate, Tool_Blur, Tool_Step, Tool_Crop,
	Undo, Redo, Paste, Delete, Delete_All, Duplicate, Bring_To_Front, Bring_Forward, Send_Backward, Send_To_Back, Remove_Crop,
	Zoom_In, Zoom_Out, Zoom_Fit, Zoom_Actual,
	Copy, Save, Save_As, Upload, Pin, Print, Done,
	Close, Palette, Keys,
	Nudge,
}

// The place among the others each order's action gives the selection.
EDITOR_ORDERS := [?]struct { action: Editor_Action, order: Edit_Order }{
	{.Bring_To_Front, .Front}, {.Bring_Forward, .Forward}, {.Send_Backward, .Backward}, {.Send_To_Back, .Back},
}

EDITOR_ACTIONS := [Editor_Action]ui.Command{
	.Tool_Select      = {label = i18n.later("Select and move"), group = i18n.later("Tools"), keys = {{.V, {}}}, icon = lucide.MOUSE_POINTER_2, tags = {"pointer", "move", "resize"}},
	.Tool_Rectangle   = {label = i18n.later("Rectangle"), group = i18n.later("Tools"), keys = {{.R, {}}}, icon = lucide.SQUARE, tags = {"box", "square", "frame"}},
	.Tool_Ellipse     = {label = i18n.later("Ellipse"), group = i18n.later("Tools"), keys = {{.E, {}}}, icon = lucide.CIRCLE, tags = {"circle", "oval", "round"}},
	.Tool_Arrow       = {label = i18n.later("Arrow"), group = i18n.later("Tools"), keys = {{.A, {}}}, icon = lucide.ARROW_UP_RIGHT, tags = {"point", "show"}},
	.Tool_Line        = {label = i18n.later("Line"), group = i18n.later("Tools"), keys = {{.L, {}}}, icon = lucide.SLASH, tags = {"straight", "rule"}},
	.Tool_Pen         = {label = i18n.later("Pen"), group = i18n.later("Tools"), keys = {{.P, {}}}, icon = lucide.PENCIL, tags = {"freehand", "draw", "brush"}},
	.Tool_Text        = {label = i18n.later("Text"), group = i18n.later("Tools"), keys = {{.T, {}}}, icon = lucide.TYPE, tags = {"label", "write", "words"}},
	.Tool_Highlighter = {label = i18n.later("Highlighter"), group = i18n.later("Tools"), keys = {{.H, {}}}, icon = lucide.HIGHLIGHTER, tags = {"marker", "yellow", "emphasis"}},
	.Tool_Pixelate    = {label = i18n.later("Pixelate"), group = i18n.later("Tools"), keys = {{.B, {}}}, icon = lucide.LAYOUT_GRID, tags = {"hide", "censor", "mosaic", "redact"}},
	.Tool_Blur        = {label = i18n.later("Blur"), group = i18n.later("Tools"), keys = {{.G, {}}}, icon = lucide.DROPLETS, tags = {"hide", "censor", "gaussian", "soft", "redact"}},
	.Tool_Step        = {label = i18n.later("Step number"), group = i18n.later("Tools"), keys = {{.N, {}}}, icon = lucide.LIST_ORDERED, tags = {"counter", "badge", "numbered"}},
	.Tool_Crop        = {label = i18n.later("Crop"), group = i18n.later("Tools"), keys = {{.C, {}}}, icon = lucide.CROP, tags = {"cut", "trim"}},
	.Undo             = {label = i18n.later("Undo"), group = i18n.later("Edit"), keys = {{.Z, {.Ctrl}}}, icon = lucide.UNDO_2, tags = {"back", "revert"}},
	.Redo             = {label = i18n.later("Redo"), group = i18n.later("Edit"), keys = {{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}}}, icon = lucide.REDO_2, tags = {"again", "forward"}},
	.Paste            = {label = i18n.later("Paste a picture or a text"), group = i18n.later("Edit"), keys = {{.V, {.Ctrl}}, {.Insert, {.Shift}}}, icon = lucide.CLIPBOARD_PASTE, tags = {"clipboard", "image", "insert"}},
	.Delete           = {label = i18n.later("Delete the selection"), group = i18n.later("Edit"), keys = {{.Delete, {}}, {.Backspace, {}}}, icon = lucide.TRASH_2, tags = {"remove", "erase"}},
	.Delete_All       = {label = i18n.later("Delete every annotation"), group = i18n.later("Edit"), keys = {{.Delete, {.Ctrl, .Shift}}}, icon = lucide.BRUSH_CLEANING, tags = {"clear", "remove", "all", "erase"}},
	.Duplicate        = {label = i18n.later("Duplicate the selection"), group = i18n.later("Edit"), keys = {{.D, {.Ctrl}}}, icon = lucide.COPY, tags = {"clone", "copy"}},
	.Bring_To_Front   = {label = i18n.later("Bring to front"), group = i18n.later("Edit"), keys = {{.Home, {}}}, icon = lucide.BRING_TO_FRONT, tags = {"order", "top", "raise", "above"}},
	.Bring_Forward    = {label = i18n.later("Bring forward"), group = i18n.later("Edit"), keys = {{.Page_Up, {}}}, icon = lucide.ARROW_UP, tags = {"order", "raise", "up"}},
	.Send_Backward    = {label = i18n.later("Send backward"), group = i18n.later("Edit"), keys = {{.Page_Down, {}}}, icon = lucide.ARROW_DOWN, tags = {"order", "lower", "down"}},
	.Send_To_Back     = {label = i18n.later("Send to back"), group = i18n.later("Edit"), keys = {{.End, {}}}, icon = lucide.SEND_TO_BACK, tags = {"order", "bottom", "lower", "below"}},
	.Remove_Crop      = {label = i18n.later("Remove the crop"), group = i18n.later("Edit"), icon = lucide.CROP, tags = {"uncrop", "whole", "reset"}},
	.Zoom_In          = {label = i18n.later("Zoom in"), group = i18n.later("View"), keys = {{.Equal, {.Ctrl}}, {.Num_Add, {.Ctrl}}}, icon = lucide.ZOOM_IN, tags = {"larger", "magnify"}},
	.Zoom_Out         = {label = i18n.later("Zoom out"), group = i18n.later("View"), keys = {{.Minus, {.Ctrl}}, {.Num_Subtract, {.Ctrl}}}, icon = lucide.ZOOM_OUT, tags = {"smaller"}},
	.Zoom_Fit         = {label = i18n.later("Fit the picture to the window"), group = i18n.later("View"), keys = {{.N0, {.Ctrl}}}, icon = lucide.MAXIMIZE, tags = {"zoom", "whole", "reset"}},
	.Zoom_Actual      = {label = i18n.later("Actual size (100 %)"), group = i18n.later("View"), keys = {{.N1, {.Ctrl}}}, icon = lucide.SCAN, tags = {"zoom", "pixels", "one to one", "100"}},
	.Copy             = {label = i18n.later("Copy the picture"), group = i18n.later("Picture"), keys = {{.C, {.Ctrl}}}, icon = lucide.CLIPBOARD_COPY, tags = {"clipboard"}},
	.Save             = {label = i18n.later("Save the picture"), group = i18n.later("Picture"), keys = {{.S, {.Ctrl}}}, icon = lucide.SAVE, tags = {"file", "png", "write"}},
	.Save_As          = {label = i18n.later("Save the picture as…"), group = i18n.later("Picture"), keys = {{.S, {.Ctrl, .Shift}}}, icon = lucide.FILE_INPUT, tags = {"file", "folder", "name", "format", "jpeg", "webp", "png", "dialog"}},
	.Upload           = {label = i18n.later("Upload the picture"), group = i18n.later("Picture"), keys = {{.U, {.Ctrl}}}, icon = lucide.CLOUD_UPLOAD, tags = {"share", "host", "link", "url", "address", "imgur", "sxcu"}},
	.Pin              = {label = i18n.later("Pin the picture to the screen"), group = i18n.later("Picture"), keys = {{.T, {.Ctrl}}}, icon = lucide.PIN, tags = {"float", "on top", "sticky", "keep", "window"}},
	.Print            = {label = i18n.later("Print the picture"), group = i18n.later("Picture"), keys = {{.P, {.Ctrl}}}, icon = lucide.PRINTER, tags = {"paper", "printer", "page"}},
	.Done             = {label = i18n.later("Done: the workflow goes on"), group = i18n.later("Picture"), keys = {{.Return, {}}}, icon = lucide.CHECK, tags = {"finish", "apply", "upload", "ok"}},
	.Close            = {label = i18n.later("Close the editor"), group = i18n.later("Window"), keys = {{.W, {.Ctrl}}}, icon = lucide.X, tags = {"discard", "cancel", "quit"}},
	.Palette          = {label = i18n.later("Command palette"), group = i18n.later("Window"), keys = {{.K, {.Ctrl}}, {.P, {.Ctrl, .Shift}}}, icon = lucide.COMMAND, tags = {"actions", "search"}},
	.Keys             = {label = i18n.later("Keyboard shortcuts"), group = i18n.later("Window"), keys = {{.F1, {}}}, icon = lucide.KEYBOARD, tags = {"help", "keys"}},
	.Nudge            = {label = i18n.later("Move the selection a pixel (arrows; with Shift, ten)"), group = i18n.later("Edit"), keys = {{.Left, {}}, {.Left, {.Shift}}}, icon = lucide.MOUSE_POINTER_2, tags = {"nudge"}},
}

EDITOR_COLOR_NAMES := [len(EDIT_COLORS)]string{i18n.later("Red"), i18n.later("Orange"), i18n.later("Yellow"), i18n.later("Green"), i18n.later("Blue"), i18n.later("Purple"), i18n.later("Black"), i18n.later("White")}

// What a filter of the picture makes: a mosaic (Pixelate), a blurred copy (Blur).
Editor_Filter_Kind :: enum u8 { Mosaic, Blur }

// A mosaic or a blurred copy of the picture, made by a task of the chores (it reads every pixel). The task owns this
// until `ended`.
Editor_Filter_Work :: struct {
	rgba:    []u8,   // the editor's picture, read only
	size:    [2]int,
	kind:    Editor_Filter_Kind,
	amount:  int,    // picture pixels: a mosaic's cell, a blur's radius
	mosaic:  Edit_Mosaic,
	blurred: []u8,   // the blurred copy (owned), of blurred_size, each pixel `cell` picture pixels
	blurred_size: [2]int,
	cell:    int,
	cancel:  bool,   // atomic: the picture goes, the task stops early
	ended:   sync.One_Shot_Event,
	app:     ^App,
}

// A filter asked for this picture: being made (work), or made (its mosaic in Editor.mosaics, its copy in Editor.blurs).
Editor_Filter :: struct {
	kind:   Editor_Filter_Kind,
	amount: int,
	work:   ^Editor_Filter_Work,   // nil once taken
}

// A picture of the clipboard decoded by a task of the chores (PNG, JPEG, BMP...). Who frees it is whoever comes last,
// as for Editor_Load_Work.
Editor_Decode_Work :: struct {
	mime:  string,   // owned
	data:  []u8,     // owned: the picture as its owner gave it
	rgba:  []u8,     // owned once decoded
	size:  [2]int,
	ok:    bool,
	state: Load_State,   // atomic
	app:   ^App,
}

// The paste (Ctrl+V): one state machine.
//
//   Idle --Ctrl+V--> Asking (a picture) --a picture--> Decoding --its pixels--> Idle (the picture added)
//   Asking (a picture) --none--> Asking (a text) --a text--> Idle (the text added); --none--> Idle (said)
//
// A new Ctrl+V starts again (the answer to an older ask has another id: it is let go); the picture going stops it.
Editor_Paste_Idle     :: struct {}
Editor_Paste_Asking   :: struct { id: u64, format: platform.Clipboard_Format, at: Edit_Vec }   // at: picture pixels
Editor_Paste_Decoding :: struct { work: ^Editor_Decode_Work, at: Edit_Vec }
Editor_Paste :: union #no_nil { Editor_Paste_Idle, Editor_Paste_Asking, Editor_Paste_Decoding }

// Which colour the colour popover changes.
Editor_Color_Target :: enum u8 { None, Stroke, Fill }

// A picture file (PNG, JPEG, WebP, BMP) read and decoded by a task of the chores (editor_open_file). Who frees it is whoever comes last: the task
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
	sheet:       ui.Shortcuts_Sheet,
	asking:      bool,       // the question before the changes are dropped
	close_due:   bool,       // closed in a frame: acted on after it (editor_after_frame)
	done_due:    bool,       // Done with nothing changed, in a frame: acted on after it (what follows may open a window)

	model:       Edit_Model,
	has_picture: bool,
	shot:        Shot,       // the picture as taken (owned while has_picture)
	tex:         render.Texture,
	tex_size:    [2]int,
	font_bold:   font.Font_Id,   // the interface's font in bold (a bold text's)
	filters:     [dynamic]Editor_Filter,
	mosaics:     [dynamic]Edit_Mosaic,
	blurs:       [dynamic]Edit_Blur,
	filters_revision: u64,        // the document's revision its shapes' filters were asked at
	images:      [dynamic]Edit_Image,   // the pictures pasted (their textures), for the picture's life
	image_next:  u32,
	paste:       Editor_Paste,
	load_work:   ^Editor_Load_Work,   // a file being read (editor_open_file)
	load_problem: string,             // why the file could not be shown (static text; "" none)
	export_wait: bool,                // an export asked while a filter was made: it starts once they are (export_wait_for)
	export_wait_for: Edit_Export_Purpose,
	save_as:     Editor_Save_As,      // editor_output.odin
	save_as_serial: u64,              // the ask the dialog's answer must name
	drops:       [dynamic]string,     // the files dropped in a frame, opened after it (owned)

	// the colour popover: which colour, the picker, the buttons it opens from (their rects, and which were built this
	// frame), the shape it was opened for (another selected: it closes)
	color_target: Editor_Color_Target,
	color_pick:   ui.Color_Pick,
	color_anchor: [Editor_Color_Target]ui.Rect,
	color_built:  bit_set[Editor_Color_Target],
	color_shape:  int,
	color_rect:   Edit_Box,   // where the popover was last laid out, window pixels (a press outside closes it)

	shape_menu_due: bool,       // a right press on a shape: its menu opens at shape_menu_at in the next build
	shape_menu_at:  Edit_Vec,

	field:        ui.Text_Edit,   // the text being typed
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
	edit_model_init(&ed.model, shot.size, scale, editor_measure, ed)
	editor_choices_load(app, &ed.model)
	ed.field_typing = 0
	ed.asking, ed.close_due, ed.done_due, ed.exporting, ed.export_wait = false, false, false, false, false
	ed.filters_revision = 0
	ed.color_target = .None
	ed.shape_menu_due = false
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

// The picture file at `path` (not kept: PNG, JPEG, WebP, BMP, by its first bytes) in an editor of its own, read and
// decoded by a task of the chores: the window says so meanwhile, and says why when the file cannot be read.
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
		img, _, ok := pic.decode(bytes)
		delete(bytes)
		if ok { work.rgba, work.size, work.ok = img.pixels, {img.width, img.height}, true }
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
	if !host.host_open(&ed.host, &app.shared, {title = i18n.tr("cliche editor"), size = EDITOR_SIZE, headless = headless}, editor_build, ed) {
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
	// (once per window: the face is looked for, and kept by the fonts' state)
	ed.font_bold = font.styled_face(&app.shared.fonts, app.shared.font, true, false)
	// (a picture file dropped on the window opens; offscreen there is no drag to come)
	if !headless && !platform.drop_target_enable(ed.host.win, true) { log.warn("the editor takes no files dropped here") }
	append(&app.editors, ed)
	app_wake_add(app, ed.host.win)
	return ed
}

// The editor of id `id`; nil: it is closed and freed (a result of the worker for it comes too late).
editor_find :: proc(app: ^App, id: u64) -> ^Editor {
	for ed in app.editors { if ed.id == id { return ed } }
	return nil
}

// After a frame of the editor: a file read, the filters asked and taken, a paste decoded, the flattened picture read, a
// close acted on. What its picture was for goes on last: that may give this editor a new picture (editor_take).
editor_after_frame :: proc(ed: ^Editor) {
	editor_load_take(ed)
	editor_drops_open(ed)
	if ed.has_picture {
		editor_filters_want(ed)
		editor_filters_take(ed)
		editor_paste_take(ed)
		if ed.export_wait && !editor_filters_busy(ed) {
			ed.export_wait = false
			editor_export_start(ed, ed.export_wait_for)
		}
	}
	if ed.exporting { editor_export_poll(ed) }
	if ed.done_due {
		// (the picture as it was taken: nothing to draw; what reads its pixels stops before they go on)
		ed.done_due = false
		editor_filters_stop(ed)
		editor_paste_stop(ed)
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
		ed.load_problem = i18n.tr("The picture cannot be read: it is not a PNG, JPEG, WebP or BMP file, or it is gone.")
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

// What the worker said of a save asked from an editor (Ctrl+S, Save as) or a pinned picture: told as cliche tells
// (app_announce), in that editor when it is still shown. The file is written either way: a closed editor's save is
// still said.
editor_saved :: proc(app: ^App, r: Result_Saved) {
	defer { delete(r.path); delete(r.problem) }
	window := editor_window(app, r.editor)
	switch {
	case r.problem != "":    app_announce(app, .Bad, i18n.tr("Not saved"), r.problem, window)
	case r.error != .None:   app_announce(app, .Bad, i18n.tr("Not saved"), i18n.tr(FLOW_ERROR_TEXT[r.error]), window)
	case:                    app_announce(app, .Good, i18n.tr("Saved"), r.path, window)
	}
}

// Where a message for editor `id` is shown: its window while it is shown; nil (cliche's usual place) once it is not.
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
	ui.shortcuts_sheet_destroy(&ed.sheet)
	ui.text_edit_destroy(&ed.field)
	ui.color_pick_destroy(&ed.color_pick)
	for p in ed.drops { delete(p) }
	delete(ed.drops)
	delete(ed.filters)
	delete(ed.mosaics)
	delete(ed.blurs)
	delete(ed.images)
}

// The window hidden, the picture and its shapes let go: editors_sweep frees it, or keeps it for the next picture.
@(private = "file")
editor_close :: proc(ed: ^Editor) {
	ed.palette.open = false
	ed.sheet.open = false
	ed.asking = false
	ed.color_target = .None
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
	editor_filters_stop(ed)
	editor_paste_stop(ed)
	editor_save_as_stop(ed)
	edit_export_free(&ed.export)
	ed.exporting, ed.export_wait = false, false
	if !ed.has_picture { return }
	edit_model_destroy(&ed.model)
	shot_free(&ed.shot)
	ed.has_picture = false
}

// The size of a line of text in the window's font, or its bold face (the model's measure).
@(private = "file")
editor_measure :: proc(user: rawptr, text: string, size: f32, bold: bool) -> Edit_Vec {
	ed := (^Editor)(user)
	app := ed.app
	face := bold && ed.font_bold != 0 ? ed.font_bold : app.shared.font
	m := font.metrics(&app.shared.fonts, face, size)
	return {font.text_width(&app.shared.fonts, face, size, text), m.line_height}
}

////////////////////////////////
// The filters' tasks: a mosaic or a blurred copy per size, made once per picture

// The filters the shapes need, when they changed (the document's revision), and the one the tool in use needs: asked.
// (The shapes are read only when the revision moved: not at each frame.)
@(private = "file")
editor_filters_want :: proc(ed: ^Editor) {
	m := &ed.model
	#partial switch m.tool {
	case .Pixelate: editor_filter_ask(ed, .Mosaic, edit_pixel_cell(&m.doc, m.styles[.Pixelate]))
	case .Blur:     editor_filter_ask(ed, .Blur, edit_blur_px(&m.doc, m.styles[.Blur]))
	}
	if m.doc.revision == ed.filters_revision { return }
	ed.filters_revision = m.doc.revision
	for &s in m.doc.shapes {
		#partial switch s.kind {
		case .Pixelate: editor_filter_ask(ed, .Mosaic, edit_pixel_cell(&m.doc, s.style))
		case .Blur:     editor_filter_ask(ed, .Blur, edit_blur_px(&m.doc, s.style))
		}
	}
}

// A filter of `amount` picture pixels: made by a task of the chores, unless it was asked already.
@(private = "file")
editor_filter_ask :: proc(ed: ^Editor, kind: Editor_Filter_Kind, amount: int) {
	for f in ed.filters { if f.kind == kind && f.amount == amount { return } }
	work := new(Editor_Filter_Work)
	work^ = {rgba = ed.shot.rgba, size = ed.shot.size, kind = kind, amount = amount, app = ed.app}
	run :: proc(data: rawptr) {
		work := (^Editor_Filter_Work)(data)
		switch work.kind {
		case .Mosaic: work.mosaic = edit_mosaic_make(work.rgba, work.size, work.amount, &work.cancel)
		case .Blur:   work.blurred, work.blurred_size, work.cell = edit_blur_make(work.rgba, work.size, work.amount, &work.cancel)
		}
		app := work.app   // (read first: once ended, the editor may free the work)
		sync.one_shot_event_signal(&work.ended)
		app_wake(app)
	}
	if !tasks.add(ui.chores(), run, work) {
		free(work)
		append(&ed.filters, Editor_Filter{kind = kind, amount = amount})   // (the chores are stopping: its box stays grey)
		return
	}
	append(&ed.filters, Editor_Filter{kind = kind, amount = amount, work = work})
}

// The filters whose tasks are done: a mosaic kept, a blurred copy made a texture.
@(private = "file")
editor_filters_take :: proc(ed: ^Editor) {
	for &f in ed.filters {
		work := f.work
		if work == nil || sync.atomic_load(&work.ended.state) == 0 { continue }
		f.work = nil
		switch work.kind {
		case .Mosaic:
			append(&ed.mosaics, work.mosaic)
		case .Blur:
			if len(work.blurred) > 0 {
				r := &ed.app.shared.r
				w, h := work.blurred_size.x, work.blurred_size.y
				tex := render.create_texture_rgba(r, w, h)
				if tex != 0 {
					render.update_texture_rgba(r, tex, 0, 0, w, h, work.blurred)
					append(&ed.blurs, Edit_Blur{radius = work.amount, cell = work.cell, tex = tex})
				}
			}
			delete(work.blurred)
		}
		free(work)
		ed.host.settle = max(ed.host.settle, 1)
	}
}

// Whether a filter is still being made (an export waits for it: a box would be grey in the file).
editor_filters_busy :: proc(ed: ^Editor) -> bool {
	for f in ed.filters { if f.work != nil { return true } }
	return false
}

// Whether a filter the shapes or the tool need is not made yet (clichetool's shots wait for them).
editor_filters_pending :: proc(ed: ^Editor) -> bool {
	editor_filters_want(ed)
	return editor_filters_busy(ed)
}

// Before the picture goes: the tasks read it. Told to stop, each ends within a row of cells, and is waited for. What
// was made goes with it, and the pasted pictures' textures (no shape of another picture names them).
@(private = "file")
editor_filters_stop :: proc(ed: ^Editor) {
	for f in ed.filters {
		work := f.work
		if work == nil { continue }
		sync.atomic_store(&work.cancel, true)
		sync.one_shot_event_wait(&work.ended)
		edit_mosaic_free(&work.mosaic)
		delete(work.blurred)
		free(work)
	}
	clear(&ed.filters)
	for &x in ed.mosaics { edit_mosaic_free(&x) }
	clear(&ed.mosaics)
	for b in ed.blurs { render.destroy_texture(&ed.app.shared.r, b.tex) }
	clear(&ed.blurs)
	for img in ed.images { render.destroy_texture(&ed.app.shared.r, img.tex) }
	clear(&ed.images)
	ed.filters_revision = 0
}

////////////////////////////////
// The paste (Editor_Paste)

// Ctrl+V: the clipboard asked for a picture, without waiting. What comes lands under the pointer when it is on the
// canvas, else at the canvas' centre.
@(private = "file")
editor_paste_begin :: proc(ed: ^Editor) {
	m := &ed.model
	editor_paste_stop(ed)
	at := edit_view_centre(m)
	if ed.has_pointer && edit_box_contains(m.view.canvas, ed.pointer) { at = edit_to_picture(m.view, ed.pointer) }
	editor_paste_ask(ed, .Image, at)
}

@(private = "file")
editor_paste_ask :: proc(ed: ^Editor, format: platform.Clipboard_Format, at: Edit_Vec) {
	id := platform.clipboard_request(ed.host.win, format)
	if id == 0 {
		ed.paste = Editor_Paste_Idle{}
		if format == .Image { editor_paste_ask(ed, .Text, at) } else { editor_paste_nothing(ed) }
		return
	}
	ed.paste = Editor_Paste_Asking{id = id, format = format, at = at}
}

// The clipboard's answer (its text and bytes live until the next events: what is kept is copied here).
@(private = "file")
editor_paste_reply :: proc(ed: ^Editor, r: platform.Clipboard_Reply) {
	s, asking := ed.paste.(Editor_Paste_Asking)
	if !asking || r.id != s.id { return }
	ed.paste = Editor_Paste_Idle{}
	switch s.format {
	case .Image:
		if !r.ok || len(r.data) == 0 { editor_paste_ask(ed, .Text, s.at); return }
		work := new(Editor_Decode_Work)
		work^ = {mime = strings.clone(r.mime), data = slice.clone(r.data), app = ed.app}
		run :: proc(data: rawptr) {
			work := (^Editor_Decode_Work)(data)
			if img, ok := platform.clipboard_image_decode(work.mime, work.data); ok { work.rgba, work.size, work.ok = img.rgba, img.size, true }
			app := work.app
			if _, done := sync.atomic_compare_exchange_strong(&work.state, .Running, .Done); done {
				app_wake(app)
				return
			}
			// (the editor gave it up meanwhile: nobody takes it)
			editor_decode_free(work)
		}
		if !tasks.add(ui.chores(), run, work) { editor_decode_free(work); return }
		ed.paste = Editor_Paste_Decoding{work = work, at = s.at}
	case .Text:
		if !r.ok || !edit_paste_text(&ed.model, r.text, s.at) { editor_paste_nothing(ed) }
	case .Html, .Files:
	}
}

@(private = "file")
editor_paste_nothing :: proc(ed: ^Editor) {
	app_announce(ed.app, .Info, i18n.tr("Nothing to paste"), i18n.tr("The clipboard holds no picture and no text."), &ed.host)
}

// The picture pasted, once decoded: a texture of its own, and a shape on the picture.
@(private = "file")
editor_paste_take :: proc(ed: ^Editor) {
	s, decoding := ed.paste.(Editor_Paste_Decoding)
	if !decoding || sync.atomic_load(&s.work.state) != .Done { return }
	ed.paste = Editor_Paste_Idle{}
	work := s.work
	defer editor_decode_free(work)
	if !work.ok {
		app_announce(ed.app, .Bad, i18n.tr("The clipboard's picture cannot be read"), "", &ed.host)
		return
	}
	r := &ed.app.shared.r
	tex := render.create_texture_rgba(r, work.size.x, work.size.y, mips = true)
	if tex == 0 { return }
	render.update_texture_rgba(r, tex, 0, 0, work.size.x, work.size.y, work.rgba)
	ed.image_next += 1
	append(&ed.images, Edit_Image{id = ed.image_next, tex = tex, size = work.size})
	edit_paste_image(&ed.model, ed.image_next, work.size, s.at)
	ed.host.settle = max(ed.host.settle, 2)
}

// The paste let go (the picture goes, or a new Ctrl+V): a decoding task is given up, without a wait.
@(private = "file")
editor_paste_stop :: proc(ed: ^Editor) {
	if s, decoding := ed.paste.(Editor_Paste_Decoding); decoding {
		if _, given_up := sync.atomic_compare_exchange_strong(&s.work.state, .Running, .Given_Up); !given_up { editor_decode_free(s.work) }
	}
	ed.paste = Editor_Paste_Idle{}
}

@(private = "file")
editor_decode_free :: proc(work: ^Editor_Decode_Work) {
	delete(work.mime)
	delete(work.data)
	delete(work.rgba)
	free(work)
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
	// (a file dropped opens with a picture or without one: before anything else)
	for e in events {
		#partial switch e.kind {
		case .Drop_Enter, .Drop_Over, .Drop_Leave, .Drop: editor_drop_event(ed, e)
		}
	}
	if !ed.has_picture {
		return events
	}
	blocked := ed.palette.open || ed.sheet.open || ed.asking || ed.exporting || ed.export_wait || ui.menu_any_open()
	_, typing := m.mode.(Edit_Typing)
	for e in events {
		#partial switch e.kind {
		case .Clipboard_Data:
			editor_paste_reply(ed, e.clipboard)   // (another's ask, a field's paste, goes on to the widgets)
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
			if ed.color_target != .None {
				// (the colour popover takes its own presses; one elsewhere closes it and does nothing else on the canvas)
				anchor := ed.color_anchor[ed.color_target]
				if !edit_box_contains(ed.color_rect, e.pos) && !edit_box_contains({anchor.min, anchor.max}, e.pos) { ed.color_target = .None }
				break
			}
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
			was_idle := edit_idle(m)
			took := edit_step(m, Edit_Press{at = e.pos, button = button, shift = .Shift in e.mods, pan = ed.space, double = double})
			// (a right press that took a shape: its menu, in the next build; one that ended a text opens nothing)
			if took && button == .Right && was_idle && edit_has_selection(m) { ed.shape_menu_due, ed.shape_menu_at = true, e.pos }
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
			if blocked || ed.color_target != .None || !edit_box_contains(m.view.canvas, e.pos) { break }
			edit_step(m, Edit_Wheel{at = e.pos, delta = e.delta, zoom = .Ctrl in e.mods, sideways = .Shift in e.mods})
			continue
		}
		append(&out, e)
	}
	return out[:]
}

// A drag over the window: taken as a copy when it may hold a picture file (Windows says its files as it enters; X11
// and Wayland only its types until the drop). Dropped: its pictures are kept to open after the frame, each in an
// editor of its own (this one keeps its picture and its changes).
@(private = "file")
editor_drop_event :: proc(ed: ^Editor, e: platform.Event) {
	win := ed.host.win
	#partial switch e.kind {
	case .Drop_Enter, .Drop_Over:
		files := false
		if d := platform.drop_data(win); d != nil && len(d.files) > 0 {
			for f in d.files { if picture_file(f) { files = true } }
		} else {
			for t in platform.drop_types(win) { if t == "text/uri-list" { files = true } }
		}
		effect: Maybe(platform.Drop_Effect)
		if files && .Copy in e.drop_allowed { effect = .Copy }
		platform.drop_set_effect(win, effect)
	case .Drop:
		d := platform.drop_data(win)
		if d == nil { return }
		open, left_out := drop_pictures(d.files[:])
		for p in open { append(&ed.drops, strings.clone(p)) }
		if left_out { app_announce(ed.app, .Info, i18n.tr("Only pictures open here"), i18n.tr("PNG, JPEG, WebP and BMP files, each in an editor of its own."), &ed.host) }
		platform.drop_data_release(win)
	case .Drop_Leave:
	}
}

// The files dropped in the last frame, each in an editor of its own: after the frame, since a new window may open.
@(private = "file")
editor_drops_open :: proc(ed: ^Editor) {
	if len(ed.drops) == 0 { return }
	paths := ed.drops
	ed.drops = {}
	defer { for p in paths { delete(p) }; delete(paths) }
	for p in paths { editor_open_file(ed.app, p) }
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
	case .Rectangle, .Ellipse, .Arrow, .Line, .Pen, .Highlighter, .Pixelate, .Blur, .Step, .Crop: ed.hover = .Crosshair
	}
}

@(private = "file")
handle_cursor :: proc(h: Edit_Handle) -> platform.Cursor {
	switch h {
	case .Top_Left, .Bottom_Right, .Scale: return .Resize_NWSE
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
	if !ed.has_picture || ed.exporting || ed.export_wait || ed.done_due { return a == .Close || a == .Palette || a == .Keys }
	#partial switch a {
	case .Undo:                         return edit_can_undo(m)
	case .Redo:                         return edit_can_redo(m)
	case .Paste:                        return edit_idle(m)
	case .Delete, .Duplicate, .Nudge:   return edit_idle(m) && edit_has_selection(m)
	case .Delete_All:                   return edit_idle(m) && len(m.doc.shapes) > 0
	case .Bring_To_Front, .Bring_Forward, .Send_Backward, .Send_To_Back:
		for o in EDITOR_ORDERS { if o.action == a { return edit_can_order(m, o.order) } }
	case .Remove_Crop:                  return edit_idle(m) && m.doc.has_crop
	case .Save_As:
		_, idle := ed.save_as.(Editor_Save_As_Idle)
		return idle
	}
	return true
}

@(private = "file")
editor_action :: proc(ed: ^Editor, a: Editor_Action) {
	m := &ed.model
	switch a {
	case .Tool_Select, .Tool_Rectangle, .Tool_Ellipse, .Tool_Arrow, .Tool_Line, .Tool_Pen, .Tool_Text, .Tool_Highlighter,
	     .Tool_Pixelate, .Tool_Blur, .Tool_Step, .Tool_Crop:
		edit_tool_set(m, Edit_Tool(int(a) - int(Editor_Action.Tool_Select)))
	case .Undo:        edit_undo(m)
	case .Redo:        edit_redo(m)
	case .Paste:       editor_paste_begin(ed)
	case .Delete:      edit_delete(m)
	case .Delete_All:  edit_delete_all(m)
	case .Duplicate:   edit_duplicate(m)
	case .Bring_To_Front, .Bring_Forward, .Send_Backward, .Send_To_Back:
		for o in EDITOR_ORDERS { if o.action == a { edit_order(m, o.order) } }
	case .Remove_Crop: edit_crop_clear(m)
	case .Zoom_In:     edit_view_zoom_centre(m, EDIT_ZOOM_STEP)
	case .Zoom_Out:    edit_view_zoom_centre(m, 1 / EDIT_ZOOM_STEP)
	case .Zoom_Fit:    edit_view_fit(m)
	case .Zoom_Actual: edit_view_zoom_to(m, 1)
	case .Copy:        editor_export_start(ed, .Copy)
	case .Save:        editor_export_start(ed, .Save)
	case .Save_As:     editor_save_as_begin(ed)
	case .Upload:      editor_export_start(ed, .Upload)
	case .Pin:         editor_export_start(ed, .Pin)
	case .Print:       editor_export_start(ed, .Print)
	case .Done:        editor_export_start(ed, .Done)
	case .Close:       editor_close_asked(ed)
	case .Palette:     ui.palette_open(&ed.palette)
	case .Keys:        ed.sheet.open = true
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
// it was taken: nothing to draw. While a mosaic or a blurred copy is still made, the export waits for it (its box would
// be a grey block in the file): editor_after_frame starts it then. A Save as whose export cannot start lets its path go.
editor_export_start :: proc(ed: ^Editor, purpose: Edit_Export_Purpose) {
	m := &ed.model
	if !ed.has_picture || ed.exporting || ed.export_wait || ed.done_due {
		if purpose == .Save_As { editor_save_as_stop(ed) }
		return
	}
	if _, typing := m.mode.(Edit_Typing); typing { edit_step(m, Edit_Type_End{keep = true}) }
	if !edit_idle(m) {
		if purpose == .Save_As { editor_save_as_stop(ed) }
		return
	}
	if purpose == .Done && !edit_changed(m) {
		// (after the frame, not in this build: the run may open another editor's window)
		ed.done_due = true
		return
	}
	ed.color_target = .None
	if editor_filters_pending(ed) {
		ed.export_wait, ed.export_wait_for = true, purpose
		ed.host.settle = max(ed.host.settle, 2)
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
		if purpose == .Save_As { editor_save_as_stop(ed) }
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
	case .Save_As:
		editor_save_as_write(ed, shot)
	case .Upload:
		app_announce(app, .Info, i18n.tr("Uploading…"), "", &ed.host)
		worker_send(&app.worker, Job_Upload{editor = ed.id, shot = shot, uploader = strings.clone(app.settings.uploader), pattern = strings.clone(app.settings.name_pattern)})
	case .Pin:
		// (as large on the screen as the picture it came from: its pixels per logical pixel; after the frame: its window
		// may open now)
		pinned := shot
		pinned.scale = ed.shot.scale
		pin_open(app, pinned)
	case .Print:
		editor_print(ed, shot)
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

	// (the colour popover closes with Escape, or when the shape it was for is no longer the one selected)
	if ed.color_target != .None && !ed.palette.open && !ed.sheet.open && ui.key_press(.Escape) { ed.color_target = .None }
	if ed.color_target != .None && ed.color_shape != m.doc.selected { ed.color_target = .None }
	ed.color_built = {}

	// (while a text is typed, its field has the keys: no command takes a letter from it; nor while the colour popover
	// is open: its field takes a colour's letters)
	_, typing := m.mode.(Edit_Typing)
	dialog := ed.palette.open || ed.sheet.open || ed.asking || ui.toolbar_menu_open(EDITOR_BAR) || ed.color_target != .None
	if !dialog && !typing && !ed.exporting && !ed.export_wait {
		if ui.key_press(.Escape) {
			if !edit_deselect(m) { editor_close_asked(ed) }
		}
		editor_nudge_keys(ed)
		for a in Editor_Action {
			if a == .Nudge { continue }
			if ui.command_pressed(EDITOR_ACTIONS[a], !editor_action_enabled(ed, a)) { editor_action(ed, a); break }
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
	// (the button the popover opened from is gone: a property the selection no longer has, a folded bar)
	if ed.color_target != .None && ed.color_target not_in ed.color_built { ed.color_target = .None }
	// (after the canvas: drawn over it, and first for the pointer)
	editor_text_field(ed, em)
	editor_color_popover(ed)
	editor_shape_menu(ed)
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
		ui.text_edit_set(&ed.field, sh.text)
		ui.text_edit_select_all(&ed.field)
	}
	size := max(edit_text_px(&m.doc, sh) * m.view.zoom, em * 0.8)
	face := sh.style.bold && ed.font_bold != 0 ? ed.font_bold : app.shared.font
	at := edit_to_window(m.view, sh.a)
	pad := math.round(em * 0.3)
	// (as wide as its longest line, as tall as its lines: the field grows with what is typed; a pass over the text
	// typed, not over the document)
	text := ui.text_edit_string(&ed.field)
	text_w: f32
	lines := 1
	rest := text
	for {
		nl := strings.index_byte(rest, '\n')
		text_w = max(text_w, font.text_width(&app.shared.fonts, face, size, nl < 0 ? rest : rest[:nl]))
		if nl < 0 { break }
		rest = rest[nl + 1:]
		lines += 1
	}
	w := max(text_w + 2 * pad + size, em * 8)
	// (the field's own line height: text_edit's is its font's and a little more)
	lh := math.round(font.metrics(&app.shared.fonts, face, size).line_height * 1.15)
	hgt := f32(lines) * lh + 2 * pad
	ed.field_rect = {at - pad, at - pad + {w, hgt}}
	ui.next({fixed_x = at.x - pad, fixed_y = at.y - pad, width = ui.px(w), height = ui.px(hgt), font = face, font_size = size, text_pad = pad, fg = edit_color(sh.style.color)})
	res := ui.text_edit("###edit_text", &ed.field, {placeholder = i18n.tr("Text"), own_menu = true, enter_commits = true, auto_height = true})
	if fresh || !ed.field_shown { ui.set_focus(res.box.key) }
	ed.field_shown = true
	// (what was typed in the frame of Enter is kept with it)
	if res.changed { edit_step(m, Edit_Typed{text = ui.text_edit_string(&ed.field)}) }
	if res.committed {
		edit_step(m, Edit_Type_End{keep = true})
	} else if res.cancelled {
		edit_step(m, Edit_Type_End{keep = false})
	}
}

// The bar: the tools, the properties, then what is done with the picture. A window too narrow for all of it folds the
// properties first, then undo, redo, copy, save, upload and pin, then the tools, into the bar's "…" panel; Cancel and
// Done stay. Save as and Print are in the palette and on their keys.
@(private = "file")
editor_bar :: proc(ed: ^Editor, em: f32) {
	m := &ed.model
	side := math.round(em * 2.2)
	ui.next({width = ui.fill(), height = ui.px(side + math.round(em * 0.8))})
	if ui.toolbar(EDITOR_BAR) {
		ui.spacer(ui.px(em * 0.5))
		if ui.toolbar_group("tools", {priority = 2}) {
			for t in Edit_Tool {
				a := Editor_Action(int(Editor_Action.Tool_Select) + int(t))
				if bar_icon(fmt.tprintf("tool%d", int(t)), EDITOR_ACTIONS[a], side, active = m.tool == t, enabled = true) { editor_action(ed, a) }
			}
		}
		if ui.toolbar_group("properties", {separator = true}) { editor_properties(ed, em, side) }
		ui.spacer(ui.fill())
		if ui.toolbar_group("zoom", {priority = 1}) { editor_zoom(ed, em, side) }
		if ui.toolbar_group("acts", {priority = 1}) {
			for a in ([?]Editor_Action{.Undo, .Redo, .Copy, .Save, .Upload, .Pin}) {
				if bar_icon(fmt.tprintf("act%d", int(a)), EDITOR_ACTIONS[a], side, active = false, enabled = editor_action_enabled(ed, a)) { editor_action(ed, a) }
			}
		}
		if ui.toolbar_group("end", {pinned = true}) {
			ui.spacer(ui.px(em * 0.5))
			// (Cancel ends the workflow's step as given up: what hangs on its "cancelled" runs, what needs its picture does not)
			ui.next({width = ui.text_size(em * 1.2), height = ui.px(side), radius = em * 0.4})
			if ui.button("cancel", i18n.tr("Cancel"), o = {tip = ui.command_tip(EDITOR_ACTIONS[.Close])}).clicked { editor_action(ed, .Close) }
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 1.2), height = ui.px(side), radius = em * 0.4})
			if ui.button("done", i18n.tr("Done"), o = {intent = .Primary, tip = ui.command_tip(EDITOR_ACTIONS[.Done])}).clicked && editor_action_enabled(ed, .Done) { editor_action(ed, .Done) }
			ui.spacer(ui.px(em * 0.5))
		}
	}
}

// The id of the editor's tool bar (ui.toolbar_menu_open: its "…" panel has Escape).
@(private = "file") EDITOR_BAR :: "editor_bar"
@(private = "file") EDITOR_ZOOM_MENU :: "editor_zoom_menu"
@(private = "file") EDITOR_SHAPE_MENU :: "editor_shape_menu"
@(private = "file") EDITOR_COLOR_POPOVER :: "###editor_color"

// The zoom in percent; a click opens its menu: fit, 50, 100, 200, 400 %.
@(private = "file")
editor_zoom :: proc(ed: ^Editor, em, side: f32) {
	m := &ed.model
	ui.next({width = ui.text_size(em * 0.6), height = ui.px(side), radius = math.round(side * 0.22)})
	sig := ui.button("zoom", fmt.tprintf("%d %%", int(math.round(m.view.zoom * 100))), o = {face = .Ghost, tip = i18n.tr("Zoom"), lit = ui.menu_is_open(EDITOR_ZOOM_MENU)})
	if sig.clicked {
		if ui.menu_is_open(EDITOR_ZOOM_MENU) { ui.menu_close() } else { ui.menu_open(EDITOR_ZOOM_MENU, sig.box.rect, anchor = sig.box.key, search = false) }
	}
	if ui.menu(EDITOR_ZOOM_MENU) {
		c := EDITOR_ACTIONS[.Zoom_Fit]
		if ui.menu_item(i18n.tr(c.label), ui.command_shortcut(c), checked = m.view.fit).clicked { edit_view_fit(m) }
		ui.menu_separator()
		for z in EDIT_ZOOMS {
			keys := z == 1 ? ui.command_shortcut(EDITOR_ACTIONS[.Zoom_Actual]) : ""
			if ui.menu_item(fmt.tprintf("%d %%", int(z * 100)), keys, checked = !m.view.fit && abs(m.view.zoom - z) < 0.001).clicked { edit_view_zoom_to(m, z) }
		}
	}
}

// The index of the value of `values` nearest `v` (a size scaled by its handle shows the size it is nearest).
@(private = "file")
nearest :: proc(values: []f32, v: f32) -> int {
	at := 0
	for x, i in values { if abs(x - v) < abs(values[at] - v) { at = i } }
	return at
}

// A weak word before a property's control.
@(private = "file")
bar_label :: proc(id, text: string, side: f32) {
	ui.next({height = ui.px(side), text_pad = 0})
	ui.label(fmt.tprintf("%s###%s", text, id))
	ui.spacer(ui.px(math.round(ui.font_size() * 0.4)))
}

// The properties of the selection, else of the tool: what applies to its kind only.
@(private = "file")
editor_properties :: proc(ed: ^Editor, em: f32, side: f32) {
	m := &ed.model
	style, props := edit_style_shown(m)
	if props == {} { return }
	before := style
	// (each property an item of the bar's group, the most needed first: a narrow window folds the last ones into "…",
	// not all of them)
	if .Color in props { if ui.toolbar_item("colours") {
		for c, i in EDIT_COLORS {
			if swatch(fmt.tprintf("swatch%d", i), c, i18n.tr(EDITOR_COLOR_NAMES[i]), style.color == c, math.round(side * 0.62)) { style.color = c }
			ui.spacer(ui.px(math.round(em * 0.25)))
		}
		// (another colour: the colour picker, in a popover; the disc shows the colour when it is none of the swatches)
		custom := !slice.contains(EDIT_COLORS[:], style.color)
		if color_button(ed, "color_more", .Stroke, custom ? style.color : 0, custom, i18n.tr("Another colour…"), math.round(side * 0.62)) {
			editor_color_toggle(ed, .Stroke, rgb_srgba(style.color, 1))
		}
		bar_separator(em, side)
	} }
	if .Fill in props { if ui.toolbar_item("fill") {
		rgb, filled := edit_fill(style)
		tip := filled ? i18n.tr("Fill colour") : i18n.tr("Fill colour: none")
		bar_label("fill_label", i18n.tr("Fill"), side)
		if color_button(ed, "fill", .Fill, rgb, filled, tip, math.round(side * 0.62)) {
			editor_color_toggle(ed, .Fill, rgb_srgba(rgb, filled ? f32(style.fill_color >> 24) / 255 : 1))
		}
		bar_separator(em, side)
	} }
	if .Width in props { if ui.toolbar_item("width") {
		// (a slider for the feel, its field for the exact width)
		ui.next({width = ui.px(math.round(em * 13)), height = ui.px(math.round(side * 0.85))})
		ui.number("###width", &style.width, lo = f32(EDIT_WIDTH_MIN), hi = f32(EDIT_WIDTH_MAX), step = 1, unit = "px", slider = true)
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Text_Size in props { if ui.toolbar_item("text_size") {
		labels := [len(EDIT_TEXT_SIZES)]string{i18n.tr("text size, short", "S"), i18n.tr("text size, short", "M"), i18n.tr("text size, short", "L"), i18n.tr("text size, short", "XL")}
		tips := [len(EDIT_TEXT_SIZES)]string{i18n.tr("Small text"), i18n.tr("Medium text"), i18n.tr("Large text"), i18n.tr("Very large text")}
		at := nearest(EDIT_TEXT_SIZES[:], style.text_size)
		ui.next({width = ui.px(em * 10), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###text_size", labels[:], &at, tips[:]) { style.text_size = EDIT_TEXT_SIZES[at] }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Bold in props { if ui.toolbar_item("bold") {
		if bar_toggle("bold", lucide.BOLD, i18n.tr("Bold"), style.bold, side) { style.bold = !style.bold }
		ui.spacer(ui.px(em * 0.4))
	} }
	if .Text_Look in props { if ui.toolbar_item("text_look") {
		// (in Edit_Text_Look's order)
		labels := [len(Edit_Text_Look)]string{i18n.tr("text look", "Plain"), i18n.tr("text look", "Outline"), i18n.tr("text look", "Box")}
		tips := [len(Edit_Text_Look)]string{i18n.tr("The letters alone"), i18n.tr("The letters with an outline (the fill colour, else black or white)"), i18n.tr("The letters on a box (the fill colour, else black or white)")}
		at := int(style.text_look)
		ui.next({width = ui.px(em * 13), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###text_look", labels[:], &at, tips[:]) { style.text_look = Edit_Text_Look(at) }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Step_Format in props { if ui.toolbar_item("step_format") {
		// (in Edit_Step_Format's order)
		labels := [len(Edit_Step_Format)]string{"1", "a", "A", "i"}
		tips := [len(Edit_Step_Format)]string{i18n.tr("Numbers: 1, 2, 3"), i18n.tr("Small letters: a, b, c"), i18n.tr("Capital letters: A, B, C"), i18n.tr("Roman numerals: i, ii, iii")}
		at := int(style.step_format)
		ui.next({width = ui.px(em * 9), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###step_format", labels[:], &at, tips[:]) { style.step_format = Edit_Step_Format(at) }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Step_Number in props { if ui.toolbar_item("step_number") {
		// (the selected step's number; with none selected, the number the next step starts at)
		n := edit_step_number_shown(m)
		bar_label("step_number_label", edit_has_selection(m) ? i18n.tr("Number") : i18n.tr("Next"), side)
		ui.next({width = ui.px(math.round(em * 6)), height = ui.px(math.round(side * 0.85))})
		if ui.number("###step_number", &n, lo = 1, hi = 9999, step = 1) { edit_step_number_set(m, n) }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Blur_Radius in props { if ui.toolbar_item("blur_radius") {
		labels := [len(EDIT_BLUR_RADII)]string{i18n.tr("text size, short", "S"), i18n.tr("text size, short", "M"), i18n.tr("text size, short", "L"), i18n.tr("text size, short", "XL")}
		tips: [len(EDIT_BLUR_RADII)]string
		for v, i in EDIT_BLUR_RADII { tips[i] = fmt.tprintf(i18n.tr("A blur of %d px"), int(v)) }
		at := nearest(EDIT_BLUR_RADII[:], style.blur_radius)
		bar_label("blur_label", i18n.tr("Blur"), side)
		ui.next({width = ui.px(em * 10), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###blur_radius", labels[:], &at, tips[:]) { style.blur_radius = EDIT_BLUR_RADII[at] }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Pixel_Size in props { if ui.toolbar_item("pixel_size") {
		labels := [len(EDIT_PIXEL_SIZES)]string{i18n.tr("text size, short", "S"), i18n.tr("text size, short", "M"), i18n.tr("text size, short", "L"), i18n.tr("text size, short", "XL")}
		tips: [len(EDIT_PIXEL_SIZES)]string
		for v, i in EDIT_PIXEL_SIZES { tips[i] = fmt.tprintf(i18n.tr("Pixels of %d px"), int(v)) }
		at := nearest(EDIT_PIXEL_SIZES[:], style.pixel_size)
		bar_label("pixel_label", i18n.tr("Pixel size"), side)
		ui.next({width = ui.px(em * 10), height = ui.px(math.round(side * 0.85))})
		if ui.segmented("###pixel_size", labels[:], &at, tips[:]) { style.pixel_size = EDIT_PIXEL_SIZES[at] }
		ui.spacer(ui.px(em * 0.5))
	} }
	if .Shadow in props { if ui.toolbar_item("shadow") {
		// (its softness: 0, none)
		ui.next({height = ui.px(side), text_pad = 0})
		ui.label(fmt.tprintf("%s###shadow_label", i18n.tr("Shadow")))
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.px(math.round(em * 12)), height = ui.px(math.round(side * 0.85))})
		ui.number("###shadow", &style.shadow, lo = f32(0), hi = f32(EDIT_SHADOW_MAX), step = 1, unit = "px", slider = true)
		ui.spacer(ui.px(em * 0.5))
	} }
	if style != before { edit_style_set(m, style) }
}

// An icon of the bar: its command's tooltip; `active`: the tool in use.
@(private = "file")
bar_icon :: proc(id: string, c: ui.Command, side: f32, active, enabled: bool) -> bool {
	ui.next({width = ui.px(side), height = ui.px(side), radius = math.round(side * 0.22), font_size = math.round(side * 0.5)})
	return ui.button(id, icon = c.icon, o = {tip = ui.command_tip(c), face = active ? .Toggled : .Ghost, intent = active ? .Primary : .Neutral, disabled = !enabled}).clicked && enabled
}

// An icon of the bar that is on or off (bold).
@(private = "file")
bar_toggle :: proc(id, icon, tip: string, on: bool, side: f32) -> bool {
	s := math.round(side * 0.85)
	ui.next({width = ui.px(s), height = ui.px(s), radius = math.round(side * 0.22), font_size = math.round(side * 0.45)})
	return ui.button(id, icon = icon, o = {tip = tip, face = on ? .Toggled : .Ghost, intent = on ? .Primary : .Neutral}).clicked
}

// The disc that opens the colour popover for `target`: the colour when it has one (`shown`), else a plus (another
// colour) or a slash (no fill). Its rect is the popover's anchor.
@(private = "file")
color_button :: proc(ed: ^Editor, id: string, target: Editor_Color_Target, rgb: u32, shown: bool, tip: string, side: f32) -> bool {
	mark := Swatch_Mark.None
	if !shown { mark = target == .Fill ? .Slash : .Plus }
	b, clicked := swatch_box(id, rgb, tip, ed.color_target == target || (target == .Stroke && shown), side, mark)
	ed.color_anchor[target] = b.rect
	ed.color_built += {target}
	return clicked
}

// The colour popover opened for `target`, the picker starting at `c`; closed when it was open for it.
@(private = "file")
editor_color_toggle :: proc(ed: ^Editor, target: Editor_Color_Target, c: ui.Srgba) {
	if ed.color_target == target {
		ed.color_target = .None
		return
	}
	ed.color_target, ed.color_shape = target, ed.model.doc.selected
	ed.color_rect = {}
	ui.color_pick_set(&ed.color_pick, c, {format = .Hex})
}

// The colour popover under its button: the colour picker; for the fill, "none" and the swatches first. Every change
// applies at once (the changes of one drag are one undo step: edit_style_set).
@(private = "file")
editor_color_popover :: proc(ed: ^Editor) {
	if ed.color_target == .None { return }
	m := &ed.model
	style, _ := edit_style_shown(m)
	before := style
	em := ui.font_size()
	pad := math.round(em * 0.6)
	w := ui.color_picker_width() + 2 * pad
	if ui.popover(EDITOR_COLOR_POPOVER, ed.color_anchor[ed.color_target], w, .Below, align_right = false) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.px(w), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###color_row") {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###color_column") {
				if ed.color_target == .Fill {
					side := math.round(em * 1.5)
					ui.next({width = ui.children_sum(), height = ui.px(side), axis = .X, cross = .Center})
					if ui.row(.Center, id = "###fill_swatches") {
						_, filled := edit_fill(style)
						if _, clicked := swatch_box("fill_none", 0, i18n.tr("No fill"), !filled, side, .Slash); clicked { style.fill_color = 0 }
						ui.spacer(ui.px(math.round(em * 0.3)))
						for c, i in EDIT_COLORS {
							if swatch(fmt.tprintf("fill_swatch%d", i), c, i18n.tr(EDITOR_COLOR_NAMES[i]), filled && style.fill_color & 0xFFFFFF == c, side) {
								style.fill_color = EDIT_OPAQUE | c
								ui.color_pick_set(&ed.color_pick, rgb_srgba(c, 1), {format = .Hex})
							}
							ui.spacer(ui.px(math.round(em * 0.3)))
						}
					}
					ui.spacer(ui.px(pad))
				}
				if ui.color_picker("###picker", &ed.color_pick) {
					c := ui.color_pick_rgba(&ed.color_pick)
					rgb := u32(math.round(clamp(c.r, 0, 1) * 255)) << 16 | u32(math.round(clamp(c.g, 0, 1) * 255)) << 8 | u32(math.round(clamp(c.b, 0, 1) * 255))
					switch ed.color_target {
					case .Stroke: style.color = rgb
					case .Fill:   style.fill_color = u32(math.round(clamp(c.a, 0, 1) * 255)) << 24 | rgb   // (alpha 0: no fill)
					case .None:
					}
				}
			}
		}
		ui.spacer(ui.px(pad))
	}
	if r, ok := ui.popover_rect(EDITOR_COLOR_POPOVER); ok { ed.color_rect = {r.min, r.max} }
	if style != before { edit_style_set(m, style) }
}

// 0xRRGGBB and an alpha as the picker's colour.
@(private = "file")
rgb_srgba :: proc(rgb: u32, alpha: f32) -> ui.Srgba {
	return {f32(rgb >> 16 & 255) / 255, f32(rgb >> 8 & 255) / 255, f32(rgb & 255) / 255, alpha}
}

// A right press on a shape: its menu (delete, duplicate, its place among the others; delete every annotation).
@(private = "file")
editor_shape_menu :: proc(ed: ^Editor) {
	if ed.shape_menu_due {
		ed.shape_menu_due = false
		ui.menu_open(EDITOR_SHAPE_MENU, ed.shape_menu_at, search = false)
	}
	item :: proc(ed: ^Editor, a: Editor_Action) {
		c := EDITOR_ACTIONS[a]
		if ui.menu_item(i18n.tr(c.label), ui.command_shortcut(c), icon = c.icon, disabled = !editor_action_enabled(ed, a)).clicked { editor_action(ed, a) }
	}
	if ui.menu(EDITOR_SHAPE_MENU) {
		item(ed, .Duplicate)
		item(ed, .Delete)
		ui.menu_separator()
		for o in EDITOR_ORDERS { item(ed, o.action) }
		ui.menu_separator()
		item(ed, .Delete_All)
	}
}

@(private = "file")
bar_separator :: proc(em, side: f32) {
	ui.spacer(ui.px(math.round(em * 0.45)))
	ui.next({width = ui.px(max(math.round(ui.scale()), 1)), height = ui.px(math.round(side * 0.7)), bg = ui.color("border")})
	ui.build_box({.Draw_Background}, "")
	ui.spacer(ui.px(math.round(em * 0.45)))
}

// What a swatch shows instead of a colour: nothing (the colour), a plus (another colour), a slash (no colour).
@(private = "file")
Swatch_Mark :: enum u8 { None, Plus, Slash }

@(private = "file")
Swatch_Draw :: struct { color, ring, ink: draw.Color, chosen: bool, mark: Swatch_Mark, scale: f32 }

// A colour to choose: a disc, a ring around the one chosen.
@(private = "file")
swatch :: proc(id: string, rgb: u32, name: string, chosen: bool, side: f32) -> bool {
	_, clicked := swatch_box(id, rgb, name, chosen, side, .None)
	return clicked
}

@(private = "file")
swatch_box :: proc(id: string, rgb: u32, name: string, chosen: bool, side: f32, mark: Swatch_Mark) -> (box: ^ui.Box, clicked: bool) {
	d := ui.frame_new(Swatch_Draw)
	d^ = {color = edit_color(rgb), ring = ui.color("text"), ink = ui.color("text"), chosen = chosen, mark = mark, scale = ui.scale()}
	ui.next({width = ui.px(side), height = ui.px(side)})
	b := ui.custom(fmt.tprintf("###%s", id), proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Swatch_Draw)(user)
		r := b.rect
		half := (r.max.x - r.min.x) * 0.5
		inner := draw.rect_pad(r, -math.round(2 * d.scale))
		line := max(math.round(1.5 * d.scale), 1)
		switch d.mark {
		case .None:
			draw.rect(dc, inner, d.color, half)
		case .Plus:
			c, l := draw.rect_center(inner), (inner.max.x - inner.min.x) * 0.28
			draw.line(dc, c - {l, 0}, c + {l, 0}, line, d.ink)
			draw.line(dc, c - {0, l}, c + {0, l}, line, d.ink)
		case .Slash:
			k := (inner.max.x - inner.min.x) * 0.2
			draw.line(dc, {inner.max.x - k, inner.min.y + k}, {inner.min.x + k, inner.max.y - k}, line, {0.9, 0.22, 0.21, 1})
		}
		// (a hairline: black and white swatches show on any theme)
		draw.rect(dc, inner, {0.5, 0.5, 0.5, 0.6}, half, max(d.scale, 1))
		if d.chosen { draw.rect(dc, r, d.ring, half, line) }
	}, d, {.Clickable, .Draw_Hot_Effects})
	sig := ui.signal(b)
	if ui.hovered_for(sig) { if ui.tooltip() { ui.tooltip_text(name) } }
	return b, sig.clicked
}

// The palette (every action but the arrows), the sheet of keys, the question before the changes are dropped.
@(private = "file")
editor_dialogs :: proc(ed: ^Editor) {
	all := slice.enumerated_array(&EDITOR_ACTIONS)
	if ed.palette.open {
		listed := all[:len(all) - 1]   // (Nudge: its keys are the arrows)
		disabled := make([]bool, len(listed), context.temp_allocator)
		for i in 0 ..< len(listed) { disabled[i] = !editor_action_enabled(ed, Editor_Action(i)) }
		if i, _ := ui.palette(&ed.palette, listed, disabled); i >= 0 { editor_action(ed, Editor_Action(i)) }
	}
	ui.shortcuts_sheet(&ed.sheet, "keys", all, i18n.tr("The editor's keys"))
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
	paint := Edit_Paint{doc = &m.doc, picture = ed.tex, mosaics = ed.mosaics[:], blurs = ed.blurs[:], images = ed.images[:],
		font_id = app.shared.font, font_bold = ed.font_bold, fonts = &app.shared.fonts,
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
	// (a frame around all but a line or an arrow, whose two handles say where it is)
	if s.kind != .Arrow && s.kind != .Line {
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
// picture goes, and given to the next editor. A style reads "<tool> <rrggbb> <width> <shadow's softness> <fill aarrggbb>
// <text size> <text look> <bold> <step format> <blur radius> <pixel size>" (the looks and formats by their number in
// their enum), one per tool, separated by ";". A style of another form is not read: the tool keeps its default.

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
		fmt.sbprintf(&b, "%v %06x %g %g %08x %g %d %d %d %g %g", t, s.color, s.width, s.shadow, s.fill_color, s.text_size,
			int(s.text_look), s.bold ? 1 : 0, int(s.step_format), s.blur_radius, s.pixel_size)
	}
	return fmt.tprintf("%v", m.tool), strings.to_string(b)
}

// `m` given the tool and the styles that editor.tool and editor.styles say; a part not read is left as it is.
edit_choices_read :: proc(m: ^Edit_Model, tool, styles: string) {
	if t, ok := edit_tool_named(tool); ok { m.tool = t }
	rest := styles
	for part in strings.split_iterator(&rest, ";") {
		f := strings.fields(part, context.temp_allocator)
		if len(f) != 11 { continue }
		t, known := edit_tool_named(f[0])
		color, c_ok := strconv.parse_u64_of_base(f[1], 16)
		width, w_ok := strconv.parse_f32(f[2])
		shadow, sh_ok := strconv.parse_f32(f[3])
		fill, fi_ok := strconv.parse_u64_of_base(f[4], 16)
		size, s_ok := strconv.parse_f32(f[5])
		look, l_ok := strconv.parse_int(f[6])
		format, fo_ok := strconv.parse_int(f[8])
		blur, b_ok := strconv.parse_f32(f[9])
		pixel, p_ok := strconv.parse_f32(f[10])
		if !known || !c_ok || !w_ok || !sh_ok || !fi_ok || !s_ok || !l_ok || !fo_ok || !b_ok || !p_ok { continue }
		if color > 0xFFFFFF || fill > 0xFFFFFFFF || size <= 0 || look < 0 || look >= len(Edit_Text_Look) || format < 0 || format >= len(Edit_Step_Format) { continue }
		m.styles[t] = {
			color = u32(color), fill_color = u32(fill),
			width = clamp(width, EDIT_WIDTH_MIN, EDIT_WIDTH_MAX), shadow = clamp(shadow, 0, EDIT_SHADOW_MAX),
			text_size = clamp(size, EDIT_TEXT_SIZE_MIN, EDIT_TEXT_SIZE_MAX), text_look = Edit_Text_Look(look), bold = f[7] == "1",
			step_format = Edit_Step_Format(format),
			// (the choices offered: a value in between would make a mosaic or a blurred copy of its own)
			blur_radius = EDIT_BLUR_RADII[nearest(EDIT_BLUR_RADII[:], blur)], pixel_size = EDIT_PIXEL_SIZES[nearest(EDIT_PIXEL_SIZES[:], pixel)],
		}
	}
}

@(private = "file")
edit_tool_named :: proc(name: string) -> (Edit_Tool, bool) {
	for t in Edit_Tool { if fmt.tprintf("%v", t) == name { return t, true } }
	return {}, false
}
