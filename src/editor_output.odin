package cliche

// What the editor does with its picture besides Done, Copy and Save: Save as (the system's dialog, then a file of the
// format chosen there), Upload (the default host; the address on the clipboard and in the history), Print (the system's
// print dialog), and the files dropped on it. Pin is pin.odin's. Each starts from the flattened picture
// (editor_export_poll); what is slow runs off the interface's thread: the dialogs on the chores (they wait for the
// person), the encoding, the file and the network on the worker.
//
// Save as is one state machine (Editor_Save_As):
//
//   Idle --Ctrl+Shift+S--> Asking (the dialog, on the chores) --a path--> Chosen --the picture flattened--> Idle (Job_Save_As)
//   Asking --cancelled, or no dialog--> Idle;  Chosen --the export failed, the picture went--> Idle
//
// The dialog's answer names the ask it is for (its serial): one that comes for an older ask, or for a picture gone
// since, is let go.

import "core:strings"
import config "gt:config"
import i18n "gt:i18n"
import "gt:platform"
import png "gt:png"
import "gt:ui"

Editor_Save_As_Idle   :: struct {}
Editor_Save_As_Asking :: struct { serial: u64 }
Editor_Save_As_Chosen :: struct { path: string, format: Save_Format }   // path owned
Editor_Save_As :: union #no_nil { Editor_Save_As_Idle, Editor_Save_As_Asking, Editor_Save_As_Chosen }

// What a Save as's task holds: what the dialog needs, and its answer. The task owns it until its end.
@(private = "file")
Save_As_Ask :: struct {
	app:     ^App,
	editor:  u64,
	serial:  u64,
	owner:   ^platform.Window,
	source:  Source,
	pattern: string,   // owned
	folder:  string,   // owned ("": the default one)
	filter:  int,      // the filter selected first: the format chosen last
	title:   string,   // owned
	result:  platform.Dialog_Result,
}

// Ctrl+Shift+S: the system's save dialog, on the chores (it waits for the person; its suggested name needs the local
// time, which reads the time zone's file). Refused while one is open for this editor.
editor_save_as_begin :: proc(ed: ^Editor) {
	app := ed.app
	if _, idle := ed.save_as.(Editor_Save_As_Idle); !idle || !ed.has_picture { return }
	ed.save_as_serial += 1
	ed.save_as = Editor_Save_As_Asking{serial = ed.save_as_serial}
	ask := new(Save_As_Ask)
	ask^ = {
		app = app, editor = ed.id, serial = ed.save_as_serial, owner = ed.host.win, source = ed.shot.source,
		pattern = strings.clone(app.settings.name_pattern), folder = strings.clone(app.settings.folder),
		filter = save_as_index(app.settings.save_as_format), title = strings.clone(i18n.tr("Save the picture as")),
	}
	work :: proc(data: rawptr) {
		ask := (^Save_As_Ask)(data)
		format := SAVE_AS_FORMATS[ask.filter]
		pattern := ask.pattern != "" ? ask.pattern : DEFAULT_NAME_PATTERN
		name := name_with_extension(name_expand(pattern, stamp_now(), ask.source, context.temp_allocator), SAVE_FORMAT_EXTENSION[format])
		folder := ask.folder != "" ? ask.folder : save_folder_default(context.temp_allocator)
		filters := [len(SAVE_AS_FORMATS)]platform.File_Filter{
			{name = "PNG", patterns = []string{"*.png"}},
			{name = "JPEG", patterns = []string{"*.jpg", "*.jpeg"}},
			{name = "WebP", patterns = []string{"*.webp"}},
		}
		ask.result = platform.save_file_dialog({
			owner = ask.owner, title = ask.title, filters = filters[:], filter_index = ask.filter,
			start_dir = folder, remember_id = "cliche-save-as", suggested_name = name,
			default_ext = SAVE_FORMAT_EXTENSION[format][1:], overwrite_prompt = true,
		})
	}
	done :: proc(data: rawptr, _: u64) {
		ask := (^Save_As_Ask)(data)
		defer save_as_ask_free(ask)
		editor_save_as_answer(ask.app, ask.editor, ask.serial, ask.result)
	}
	lost :: proc(data: rawptr) { save_as_ask_free((^Save_As_Ask)(data)) }
	ui.task(&ed.host.state, work, done, ask, lost)
}

@(private = "file")
save_as_ask_free :: proc(ask: ^Save_As_Ask) {
	platform.dialog_result_destroy(&ask.result)
	delete(ask.pattern)
	delete(ask.folder)
	delete(ask.title)
	free(ask)
}

// The dialog's answer, in a build of its editor: a path chosen is flattened and written; cancelled, nothing.
@(private = "file")
editor_save_as_answer :: proc(app: ^App, editor, serial: u64, r: platform.Dialog_Result) {
	ed := editor_find(app, editor)
	if ed == nil { return }
	s, asking := ed.save_as.(Editor_Save_As_Asking)
	if !asking || s.serial != serial { return }
	ed.save_as = Editor_Save_As_Idle{}
	switch r.status {
	case .Chosen:
		if len(r.paths) == 0 || !ed.has_picture { return }
		path, format := save_as_choice(r.paths[0], r.filter)
		// (the format chosen is the one offered first next time)
		if format != app.settings.save_as_format {
			app.settings.save_as_format = format
			_ = config_set_string(app, "save.as_format", SAVE_AS_NAMES[save_as_index(format)])
		}
		ed.save_as = Editor_Save_As_Chosen{path = strings.clone(path), format = format}
		editor_export_start(ed, .Save_As)
	case .Cancelled:
	case .Unsupported, .Failed:
		app_announce(app, .Bad, i18n.tr("The save dialog cannot open"), i18n.tr("Ctrl+S saves to the default folder."), &ed.host)
	}
}

// The flattened picture for a Save as: to the worker, with the path chosen (`shot` taken).
editor_save_as_write :: proc(ed: ^Editor, shot: Shot) {
	shot := shot
	s, chosen := ed.save_as.(Editor_Save_As_Chosen)
	ed.save_as = Editor_Save_As_Idle{}
	if !chosen { shot_free(&shot); return }
	worker_send(&ed.app.worker, Job_Save_As{editor = ed.id, shot = shot, path = s.path, format = s.format, quality = ed.app.settings.quality})
}

// The picture goes, or its export failed: a path chosen is let go; a dialog open stays, its answer let go (serial).
editor_save_as_stop :: proc(ed: ^Editor) {
	if s, chosen := ed.save_as.(Editor_Save_As_Chosen); chosen { delete(s.path) }
	ed.save_as_serial += 1
	ed.save_as = Editor_Save_As_Idle{}
}

// A preference set from the interface (written by the preferences' writer). False: refused.
@(private = "file")
config_set_string :: proc(app: ^App, name, value: string) -> bool {
	if config.set_from_string(&app.prefs, name, value, .User) != .None { return false }
	app_prefs_changed(app)
	return true
}

////////////////////////////////
// Upload

// An editor's Upload, on the worker: its PNG sent to the host named (the settings' default), the file's name from the
// pattern.
editor_upload_work :: proc(j: ^Job_Upload) -> (out: Result_Uploaded) {
	defer { shot_free(&j.shot); delete(j.uploader); delete(j.pattern) }
	out = {editor = j.editor, size = j.shot.size, source = j.shot.source}
	file := png.encode(j.shot.rgba, j.shot.size.x, j.shot.size.y, .Fast)
	defer delete(file)
	if file == nil { out.problem = strings.clone(i18n.tr(FLOW_ERROR_TEXT[.Empty])); return }
	list, _ := uploaders_load(context.temp_allocator)
	u, _ := uploader_find(list, j.uploader)
	if u == nil { out.problem = strings.clone(i18n.tr("no uploader is set up")); return }
	file_name := name_with_extension(name_expand(j.pattern != "" ? j.pattern : DEFAULT_NAME_PATTERN, stamp_now(), j.shot.source, context.temp_allocator), ".png")
	url, problem := upload_shot(u^, file, file_name)
	if problem != "" { delete(url); out.problem = problem; return }
	out.url = url
	return
}

// The upload is done: its address on the clipboard (the anchor's: it outlives the editor's window) and in the history,
// and said where the editor is (or cliche's usual place once it is closed).
editor_uploaded :: proc(app: ^App, r: Result_Uploaded) {
	defer { delete(r.url); delete(r.problem) }
	window := editor_window(app, r.editor)
	if r.url == "" {
		app_announce(app, .Bad, i18n.tr("Not uploaded"), r.problem, window)
		return
	}
	copied := platform.clipboard_set(app.anchor, {text = r.url})
	app.notice_entry = history_note(app, {kind = history_kind_of(r.source), url = r.url, size = r.size})
	app_announce(app, .Good, copied ? i18n.tr("Uploaded: the address is on the clipboard") : i18n.tr("Uploaded"), r.url, window)
}

////////////////////////////////
// Print

// What a print's task holds (owned by it until its end).
@(private = "file")
Print_Ask :: struct {
	app:    ^App,
	editor: u64,
	owner:  ^platform.Window,
	shot:   Shot,
	title:  string,   // owned
	status: platform.Print_Status,
}

// The flattened picture printed (`shot` taken): the system's print dialog on the chores (it waits for the person),
// then the page to the printer. Said when it is over.
editor_print :: proc(ed: ^Editor, shot: Shot) {
	ask := new(Print_Ask)
	ask^ = {app = ed.app, editor = ed.id, owner = ed.host.win, shot = shot, title = strings.clone(i18n.tr("Screenshot"))}
	work :: proc(data: rawptr) {
		ask := (^Print_Ask)(data)
		ask.status = platform.print_image(ask.owner, ask.title, ask.shot.rgba, ask.shot.size)
	}
	done :: proc(data: rawptr, _: u64) {
		ask := (^Print_Ask)(data)
		defer print_ask_free(ask)
		window := editor_window(ask.app, ask.editor)
		switch ask.status {
		case .Printed:     app_announce(ask.app, .Good, i18n.tr("Sent to the printer"), "", window)
		case .Cancelled:
		case .Unsupported: app_announce(ask.app, .Bad, i18n.tr("Printing is not available here"), i18n.tr("The desktop has no print dialog cliche can use (Linux: the print portal)."), window)
		case .Failed:      app_announce(ask.app, .Bad, i18n.tr("Not printed"), i18n.tr("The printer or its dialog refused the page."), window)
		}
	}
	lost :: proc(data: rawptr) { print_ask_free((^Print_Ask)(data)) }
	ui.task(&ed.host.state, work, done, ask, lost)
}

@(private = "file")
print_ask_free :: proc(ask: ^Print_Ask) {
	shot_free(&ask.shot)
	delete(ask.title)
	free(ask)
}

////////////////////////////////
// Files dropped

// Whether a file dropped is one the editor opens: a picture by its name (PNG, JPEG, WebP, BMP). Its bytes decide in
// the end (gt:image's decode reads the signature): this only keeps a text file from opening an editor that says no.
picture_file :: proc(path: string) -> bool {
	dot := strings.last_index_byte(path, '.')
	if dot < 0 || strings.last_index_any(path, "/\\") > dot { return false }
	switch strings.to_lower(path[dot + 1:], context.temp_allocator) {
	case "png", "jpg", "jpeg", "jpe", "webp", "bmp", "dib": return true
	}
	return false
}

// The most files one drop opens: each is a window.
EDITOR_DROP_MOST :: 8

// The pictures of a drop, each to open in an editor of its own (at most EDITOR_DROP_MOST), and whether anything was
// left out (not a picture, or past the most). Temp allocator.
drop_pictures :: proc(files: []string) -> (open: []string, left_out: bool) {
	out := make([dynamic]string, 0, min(len(files), EDITOR_DROP_MOST), context.temp_allocator)
	for f in files {
		if !picture_file(f) || len(out) == EDITOR_DROP_MOST { left_out = true; continue }
		append(&out, f)
	}
	return out[:], left_out
}
