package cliche

// Pictures of cliche's windows, drawn offscreen (the software renderer: no window of the system opens): what
// `clichetool shots` asks for with -define:CLICHE_SHOTS=<folder>, one window a run (the first window is the only one a
// headless renderer has): `cliche-shots settings | editor | history | workflows`. A normal build has none of this: the folder is "".
// The preferences are their defaults (the user's file is not read), on the default theme; the editor's picture and the
// history's entries are made up here.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:host"
import pic "gt:image"
import png "gt:png"
import "gt:render"
import "gt:ui"

CLICHE_SHOTS :: #config(CLICHE_SHOTS, "")

// (only a build of the pictures holds it: a normal build has none of this file's work)
when CLICHE_SHOTS != "" {
	SHOTS_EDITOR_PICTURE := #load("../assets/shots/autumn.webp")
} else {
	SHOTS_EDITOR_PICTURE: []u8
}

// Frames drawn before a picture (the layout settles, the fonts' glyphs arrive), and frames a capture may take.
SHOTS_SETTLE_FRAMES  :: 6
SHOTS_CAPTURE_FRAMES :: 20
// How long the editor's mosaic (a task) may take before its picture is taken.
SHOTS_MOSAIC_WAIT    :: 10 * time.Second

shots_run :: proc(folder: string, which: string) -> int {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	prefs_register(&app.prefs)
	app.settings = prefs_read(&app.prefs)
	app.flow = Flow_Idle{}
	app.record = Record_Idle{}
	// (no file of the user's: the pictures show cliche's themes, and a licence kept in memory only)
	prefs_page.themes_file_init(&app.themes_file, "", themes())
	licence_init(app, memory = true)
	defer {
		settings_free(&app.settings)
		config.prefs_destroy(&app.prefs)
		delete(app.editors)
		delete(app.wakes)
		delete(app.standards)
		ui.chores_stop()   // (a task may still hold the licence's store)
		prefs_page.themes_file_destroy(&app.themes_file)
		licence_destroy(app)
	}
	_ = os.make_directory_all(folder)
	switch which {
	case "settings", "": return shots_settings(app, folder)
	case "editor":       return shots_editor(app, folder)
	case "history":      return shots_history(app, folder)
	case "workflows":    return shots_workflows(app, folder)
	case "record":       return shots_record(app, folder)
	case "motion":       return shots_motion(app, folder)
	}
	fmt.eprintfln("shots: no window %q (settings, editor, history, workflows, record, motion)", which)
	return 2
}

// The recording's overlay over a made-up output: ready (Record, the format, Cancel), then recording (the time, Stop,
// Cancel). Offscreen the window is black where a desktop would show through.
@(private = "file")
shots_record :: proc(app: ^App, folder: string) -> int {
	app.record_output = {0, 0, 1280, 720}
	app.record_region = {240, 160, 800, 380}
	app.record = Record_Ready{.Mp4}
	if !record_overlay_show(app, headless = true) { return 1 }
	ro := &app.record_overlay
	defer { app_host_close(app, &ro.host) }
	failed := !shots_write(app, &ro.host, folder, "record-ready")
	app.record = Record_Recording{.Mp4, 83_000}
	failed |= !shots_write(app, &ro.host, folder, "record-running")
	return failed ? 1 : 0
}

@(private = "file")
shots_settings :: proc(app: ^App, folder: string) -> int {
	if !history_window_open(app, headless = true) { return 1 }
	hw := &app.history_window
	defer { history_window_free(app); app_host_close(app, &hw.host) }
	settings_enter(app)
	page := &hw.settings_mode.page
	failed := false
	for pg in SETTINGS_PAGES {
		delete(page.current)
		page.current = strings.clone(pg.category)
		// (the heap: each frame frees the temporary allocator)
		name := fmt.aprintf("settings-%s", pg.category)
		failed |= !shots_write(app, &hw.host, folder, name)
		delete(name)
	}
	// the command palette, open on the first page
	delete(page.current)
	page.current = strings.clone(SETTINGS_PAGES[0].category)
	ui.palette_open(&hw.palette)
	failed |= !shots_write(app, &hw.host, folder, "settings-palette")
	return failed ? 1 : 0
}

// A landscape (assets/shots/autumn.webp: a public domain photograph, see assets/shots/README.md) with an arrow, a box, a
// text, step numbers and a pixelated part: the editor shows what it marks on a picture worth looking at.
@(private = "file")
shots_editor :: proc(app: ^App, folder: string) -> int {
	ed := editor_open(app, headless = true)
	if ed == nil { return 1 }
	defer editor_dispose(ed)
	img, ok := pic.webp_decode(SHOTS_EDITOR_PICTURE)
	if !ok { fmt.eprintln("shots: assets/shots/autumn.webp does not decode (is libwebp there?)"); return 1 }
	// (the editor takes the pixels, as it takes a capture's)
	if !editor_open_shot(ed, {rgba = img.pixels, size = {img.width, img.height}, source = .Region, scale = 1}) { return 1 }
	m := &ed.model
	st := EDIT_STYLE_DEFAULT
	edit_add(m, {kind = .Arrow, a = {990, 640}, b = {810, 345}, style = st})
	edit_add(m, {kind = .Rectangle, a = {140, 165}, b = {420, 430}, style = st})
	edit_add(m, {kind = .Text, a = {450, 190}, text = strings.clone("The best colours"), style = st})
	edit_add(m, {kind = .Step, a = {140, 165}, b = {140, 165}, number = 1, style = st})
	edit_add(m, {kind = .Step, a = {790, 320}, b = {790, 320}, number = 2, style = st})
	edit_add(m, {kind = .Pixelate, a = {1010, 395}, b = {1190, 432}, style = m.styles[.Pixelate]})
	edit_select(m, 0)   // (the arrow: its properties in the bar)
	// (the mosaic is made by a task: frames until it is there, bounded, or the pixelated box is a grey block)
	deadline := time.tick_add(time.tick_now(), SHOTS_MOSAIC_WAIT)
	for editor_filters_pending(ed) {
		if time.tick_diff(time.tick_now(), deadline) <= 0 { fmt.eprintln("shots: the editor's mosaic did not come"); return 1 }
		ed.host.settle = 1
		host.host_frame(&ed.host)
		editor_after_frame(ed)   // (what the program's loop does after a frame: it takes the task's mosaic)
		time.sleep(10 * time.Millisecond)
	}
	written := shots_write(app, &ed.host, folder, "editor")
	return written ? 0 : 1
}

@(private = "file")
shots_history :: proc(app: ^App, folder: string) -> int {
	if !history_window_open(app, headless = true) { return 1 }
	hw := &app.history_window
	defer { history_window_free(app); app_host_close(app, &hw.host) }
	now := time.to_unix_nanoseconds(time.now()) / 1_000_000
	Made :: struct { kind: History_Kind, name, url, text: string, size: [2]int, bytes, length_ms: i64 }
	made := [?]Made{
		{.Region, "cliche-20261112-101502.png", "", "", {1240, 680}, 184_320, 0},
		{.Video, "cliche-20261112-100940.mp4", "", "", {1920, 1080}, 4_812_003, 65_000},
		{.Window, "cliche-20261112-095811.png", "https://litter.catbox.moe/k2x9q1.png", "", {1600, 900}, 402_112, 0},
		{.Qr, "", "", "https://github.com/sachahjkl/cliche", {}, 0, 0},
		{.Text, "", "", "Error 0x80070005: access is denied. Run the installer as the current user.", {}, 0, 0},
		{.Screen, "cliche-20261112-091204.png", "", "", {3840, 2160}, 2_381_552, 0},
		{.Gif, "cliche-20261111-181530.gif", "", "", {960, 540}, 1_204_411, 12_000},
		{.Region, "cliche-20261111-170201.png", "", "", {420, 260}, 61_204, 0},
	}
	for e, i in made {
		path := e.name != "" ? fmt.tprintf("/home/ada/Pictures/Screenshots/%s", e.name) : ""
		history_add(&hw.history, {id = u64(i + 1), time_ms = now - i64(len(made) - i) * 1_800_000, kind = e.kind, path = path, url = e.url, text = e.text, size = e.size, bytes = e.bytes, length_ms = e.length_ms}, 1000)
	}
	failed := !shots_write(app, &hw.host, folder, "history-grid")
	app.settings.history_view = .List
	failed |= !shots_write(app, &hw.host, folder, "history-list")
	return failed ? 1 : 0
}

// The Workflows mode on the default "Screenshot" workflow, its Save step selected, as after a run.
@(private = "file")
shots_workflows :: proc(app: ^App, folder: string) -> int {
	if !history_window_open(app, headless = true) { return 1 }
	hw := &app.history_window
	app.workflows = workflows_default()
	defer { history_window_free(app); app_host_close(app, &hw.host); workflows_free(&app.workflows) }
	workflow_mode_enter(app)
	m := &hw.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil { return 1 }
	for n in wf.graph.nodes {
		m.last[n.id] = Node_Last{state = .Done}
		if Node_Kind(n.kind) == .Save_File { append(&m.selection, n.id) }
	}
	m.last_version += 1
	ok := shots_write(app, &hw.host, folder, "workflows", frames = 10)   // (the graph is fitted once laid out)
	return ok ? 0 : 1
}

// What moves, frame by frame, in the Workflows mode (motion-<step>-<nn>.png, a frame each 16 ms): a workflow's rename
// started, then another workflow shown (its triggers' switches change). For an eye on an animation, not in the defaults.
@(private = "file")
shots_motion :: proc(app: ^App, folder: string) -> int {
	if !history_window_open(app, headless = true) { return 1 }
	hw := &app.history_window
	app.workflows = workflows_default()
	defer { history_window_free(app); app_host_close(app, &hw.host); workflows_free(&app.workflows) }
	workflow_mode_enter(app)
	for _ in 0 ..< 10 { hw.host.settle = 1; host.host_frame(&hw.host); time.sleep(16 * time.Millisecond) }
	frames :: proc(app: ^App, folder, step: string, n: int) -> bool {
		hw := &app.history_window
		for i in 0 ..< n {
			if !shots_write(app, &hw.host, folder, fmt.tprintf("motion-%s-%02d", step, i), frames = 0) { return false }
			time.sleep(16 * time.Millisecond)
		}
		return true
	}
	first := app.workflows.set.list[0].id
	workflow_rename_start(app, first)
	if !frames(app, folder, "rename", 12) { return 1 }
	hw.workflow_mode.renaming = 0
	workflow_show(app, app.workflows.set.list[1].id)
	if !frames(app, folder, "switch", 16) { return 1 }
	return 0
}

// A few frames of `h`, then the next one captured and written as <folder>/<name>.png.
@(private = "file")
shots_write :: proc(app: ^App, h: ^host.Host, folder, name: string, frames := SHOTS_SETTLE_FRAMES) -> bool {
	path := fmt.aprintf("%s/%s.png", folder, name)   // (the heap: each frame frees the temporary allocator)
	defer delete(path)
	for _ in 0 ..< frames { h.settle = 1; host.host_frame(h); time.sleep(10 * time.Millisecond) }
	if !render.capture_request(&app.shared.r) { return false }
	for _ in 0 ..< SHOTS_CAPTURE_FRAMES {
		h.settle = 1
		host.host_frame(h)
		pixels, size, status := render.capture_poll(&app.shared.r)
		#partial switch status {
		case .Ready:
			defer delete(pixels)
			file := png.encode(pixels, size.x, size.y, .Small)
			defer delete(file)
			if os.write_entire_file(path, file) != nil { fmt.eprintfln("shots: %s cannot be written", path); return false }
			fmt.printfln("wrote %s", path)
			return true
		case .Failed, .None:
			return false
		}
	}
	return false
}
