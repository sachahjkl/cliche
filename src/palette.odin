package cliche

// cliche's command palettes: the toolkit's one palette (gui_toolkit's src/md/features/palette.md), fed by sources. The
// toolkit gives the commands (`>`, with the views' moves of the window it is over) and the settings (`:`); cliche gives
// its data: the captures (`@`, go to one in the history) and the workflows (`#`, the one shown marked). The workflows'
// add palette is the toolkit's chooser (ui.flow_palette). cliche's intent: src/md/features/palette.md.

import "core:fmt"
import "core:strconv"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

// The usage memory's files, in the state folder: the main window's palette, the editors'.
PALETTE_CHOICES_FILE        :: "palette_choices.txt"
EDITOR_PALETTE_CHOICES_FILE :: "editor_palette_choices.txt"

// Where a palette's usage memory is ("" in a headless window: the screenshots, the tests, memory only).
palette_choices_path :: proc(name: string, headless: bool, allocator := context.temp_allocator) -> string {
	if headless { return "" }
	return path_join(platform.user_dir(.State, APP_FOLDER, context.temp_allocator), name, allocator)
}

// An item's id: an entry's or a workflow's number, as text (the usage memory's key: never a title).
@(private = "file")
palette_id :: proc(id: u64, allocator := context.temp_allocator) -> string { return fmt.aprintf("%d", id, allocator = allocator) }

// The number an item's id holds (0: none).
palette_id_number :: proc(id: string) -> u64 {
	n, ok := strconv.parse_u64(id)
	return ok ? n : 0
}

////////////////////////////////
// `@` the captures

// The captures of the history, newest first: choosing one shows it selected in the history. Its version is the
// history's (an entry added, removed, renamed by an upload's address).
captures_source :: proc(app: ^App) -> ui.Palette_Source {
	return {
		name = "capture", title = i18n.later("Captures"), prefix = .Go_To, plain = true, remember = true, enter = i18n.later("Show"),
		read = captures_read, poll = captures_poll, user = app,
	}
}

// (at each build while the palette is open) The history changed: the captures are read again.
@(private = "file")
captures_poll :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) {
	src.version = (^App)(src.user).history_window.history.version + 1
}

@(private = "file")
captures_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	h := &app.history_window.history
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(h.entries), al)
	for i in 0 ..< len(h.entries) {
		e := h.entries[len(h.entries) - 1 - i]
		detail := e.url != "" ? e.url : e.path
		a.items[i] = ui.palette_item_clone({
			id = palette_id(e.id), title = history_name(e), detail = detail, icon = capture_icon(e), group = history_kind_text(e.kind),
			tags = {history_kind_text(e.kind)},
		}, al)
	}
	ui.palette_answer(q, &a)
}

@(private = "file")
capture_icon :: proc(e: History_Entry) -> string {
	if e.missing { return lucide.FILE }
	switch e.kind {
	case .Region, .Screen, .Window, .Picture: return lucide.IMAGE
	case .Video, .Gif:                        return lucide.FILM
	case .Qr:                                 return lucide.QR_CODE
	case .Text:                               return lucide.FILE_TEXT
	case .File:                               return lucide.FILE
	}
	return lucide.IMAGE
}

////////////////////////////////
// `#` the workflows

// The workflows, the one shown in the Workflows mode marked: choosing one shows it there. Its version is the
// workflows' (one added, renamed, deleted, its triggers changed).
workflows_source :: proc(app: ^App) -> ui.Palette_Source {
	return {
		name = "workflow", title = i18n.later("Workflows"), prefix = .Choose, plain = true, remember = true, enter = i18n.later("Show"),
		read = workflows_read, mark = workflows_mark, poll = workflows_poll, user = app,
	}
}

// (at each build while the palette is open) The workflows changed: they are read again.
@(private = "file")
workflows_poll :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) {
	src.version = (^App)(src.user).workflows.version + 1
}

@(private = "file")
workflows_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	list := app.workflows.set.list[:]
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	a.items = make([]ui.Palette_Item, len(list), al)
	for &wf, i in list {
		a.items[i] = ui.palette_item_clone({id = palette_id(wf.id), title = wf.name, detail = workflow_triggers_text(&wf), icon = lucide.GIT_FORK}, al)
	}
	ui.palette_answer(q, &a)
}

// The workflow shown (in the Workflows mode, and the one it shows when it opens).
@(private = "file")
workflows_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	app := (^App)(src.user)
	return app.history_window.workflow_mode.shown == palette_id_number(id)
}

// (the workflows' add palette is a chooser of the toolkit's: ui.flow_palette, workflow_add_feed)
