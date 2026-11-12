package cliche

// Pictures of cliche's windows, drawn offscreen (the software renderer: no window of the system opens): what
// `clichetool shots` asks for with -define:CLICHE_SHOTS=<folder>, one window a run (the first window is the only one a
// headless renderer has): `cliche-shots settings | editor | history`. A normal build has none of this: the folder is "".
// The preferences are their defaults (the user's file is not read), on the default theme; the editor's picture and the
// history's entries are made up here.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import config "gt:config"
import "gt:host"
import png "gt:png"
import "gt:render"
import "gt:ui"

CLICHE_SHOTS :: #config(CLICHE_SHOTS, "")

// Frames drawn before a picture (the layout settles, the fonts' glyphs arrive), and frames a capture may take.
SHOTS_SETTLE_FRAMES  :: 6
SHOTS_CAPTURE_FRAMES :: 20

shots_run :: proc(folder: string, which: string) -> int {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	config.register(&app.prefs, PREF_DEFS[:])
	app.settings = prefs_read(&app.prefs)
	app.flow = Flow_Idle{}
	app.record = Record_Idle{}
	defer { settings_free(&app.settings); config.prefs_destroy(&app.prefs) }
	_ = os.make_directory_all(folder)
	switch which {
	case "settings", "": return shots_settings(app, folder)
	case "editor":       return shots_editor(app, folder)
	case "history":      return shots_history(app, folder)
	}
	fmt.eprintfln("shots: no window %q (settings, editor, history)", which)
	return 2
}

@(private = "file")
shots_settings :: proc(app: ^App, folder: string) -> int {
	if !settings_window_open(app, headless = true) { return 1 }
	sw := &app.settings_window
	defer { settings_window_free(app); host.host_close(&sw.host) }
	failed := false
	for pg in SETTINGS_PAGES {
		delete(sw.page.current)
		sw.page.current = strings.clone(pg.category)
		// (the heap: each frame frees the temporary allocator)
		name := fmt.aprintf("settings-%s", pg.category)
		failed |= !shots_write(app, &sw.host, folder, name)
		delete(name)
	}
	// the command palette, open on the first page
	delete(sw.page.current)
	sw.page.current = strings.clone(SETTINGS_PAGES[0].category)
	ui.palette_open(&sw.palette)
	failed |= !shots_write(app, &sw.host, folder, "settings-palette")
	return failed ? 1 : 0
}

// A made-up screenshot (a window on a gradient) with an arrow, a box, a text, step numbers and a pixelated part.
@(private = "file")
shots_editor :: proc(app: ^App, folder: string) -> int {
	if !editor_open(app, headless = true) { return 1 }
	ed := &app.editor
	defer { editor_destroy(app); editor_free(app); host.host_close(&ed.host) }
	W, H :: 1200, 720
	px := make([]u8, W * H * 4)
	for y in 0 ..< H {
		for x in 0 ..< W {
			p := px[(y * W + x) * 4:]
			inside := x > 140 && x < 1060 && y > 90 && y < 640
			bar := inside && y < 130
			switch {
			case bar:    p[0], p[1], p[2] = 48, 52, 70
			case inside: p[0], p[1], p[2] = 236, 238, 244
			case:        p[0], p[1], p[2] = u8(30 + x / 20), u8(40 + y / 18), 90
			}
			if inside && !bar && y % 40 > 30 && x > 200 && x < 200 + (y * 7) % 600 { p[0], p[1], p[2] = 150, 156, 170 }
			p[3] = 255
		}
	}
	if !editor_open_shot(app, {rgba = px, size = {W, H}, source = .Region, scale = 1}) { return 1 }
	m := &ed.model
	st := EDIT_STYLE_DEFAULT
	edit_add(m, {kind = .Arrow, a = {880, 560}, b = {640, 330}, style = st})
	edit_add(m, {kind = .Rectangle, a = {190, 160}, b = {600, 290}, style = st})
	edit_add(m, {kind = .Text, a = {640, 170}, text = strings.clone("Click here first"), style = st})
	edit_add(m, {kind = .Step, a = {170, 150}, b = {170, 150}, number = 1, style = st})
	edit_add(m, {kind = .Step, a = {620, 300}, b = {620, 300}, number = 2, style = st})
	edit_add(m, {kind = .Pixelate, a = {700, 420}, b = {1020, 500}, style = {width = st.width, text_size = st.text_size}})
	m.doc.selected = 0   // (the arrow: its properties in the bar)
	ok := shots_write(app, &ed.host, folder, "editor", frames = 30)   // (the mosaic is made on a thread)
	return ok ? 0 : 1
}

@(private = "file")
shots_history :: proc(app: ^App, folder: string) -> int {
	if !history_window_open(app, headless = true) { return 1 }
	hw := &app.history_window
	defer { history_window_free(app); host.host_close(&hw.host) }
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
