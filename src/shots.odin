package cliche

// Pictures of the settings' pages, drawn offscreen (the software renderer: no window of the system opens): what
// `clichetool shots` asks for with -define:CLICHE_SHOTS=<folder>. A normal build has none of this: the folder is "".
// The preferences are their defaults (the user's file is not read), on the default theme.

import "core:fmt"
import "core:os"
import "core:strings"
import config "gt:config"
import "gt:host"
import png "gt:png"
import "gt:render"
import "gt:ui"

CLICHE_SHOTS :: #config(CLICHE_SHOTS, "")

// Frames drawn before a page's picture (the layout settles, the fonts' glyphs arrive), and frames a capture may take.
SHOTS_SETTLE_FRAMES  :: 4
SHOTS_CAPTURE_FRAMES :: 20

shots_run :: proc(folder: string) -> int {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	config.register(&app.prefs, PREF_DEFS[:])
	app.settings = prefs_read(&app.prefs)
	defer { settings_free(&app.settings); config.prefs_destroy(&app.prefs) }
	if !settings_window_open(app, headless = true) { return 1 }
	sw := &app.settings_window
	defer {
		settings_window_free(app)
		host.host_close(&sw.host)
	}
	_ = os.make_directory_all(folder)
	failed := false
	for pg in SETTINGS_PAGES {
		delete(sw.page.current)
		sw.page.current = strings.clone(pg.category)
		pixels, size, ok := shots_frame(app)
		if !ok { fmt.eprintfln("shots: %s: no picture", pg.category); failed = true; continue }
		file := png.encode(pixels, size.x, size.y, .Small)
		path := fmt.tprintf("%s/settings-%s.png", folder, pg.category)
		if os.write_entire_file(path, file) != nil { fmt.eprintfln("shots: %s cannot be written", path); failed = true }
		delete(file)
		delete(pixels)
		fmt.printfln("wrote %s", path)
	}
	// the command palette, open on the first page
	delete(sw.page.current)
	sw.page.current = strings.clone(SETTINGS_PAGES[0].category)
	ui.palette_open(&sw.palette)
	if pixels, size, ok := shots_frame(app); ok {
		file := png.encode(pixels, size.x, size.y, .Small)
		path := fmt.tprintf("%s/settings-palette.png", folder)
		if os.write_entire_file(path, file) == nil { fmt.printfln("wrote %s", path) } else { failed = true }
		delete(file)
		delete(pixels)
	} else {
		failed = true
	}
	return failed ? 1 : 0
}

// A few frames, then the next one captured.
@(private = "file")
shots_frame :: proc(app: ^App) -> (pixels: []u8, size: [2]int, ok: bool) {
	h := &app.settings_window.host
	for _ in 0 ..< SHOTS_SETTLE_FRAMES { h.settle = 1; host.host_frame(h) }
	if !render.capture_request(&app.shared.r) { return }
	for _ in 0 ..< SHOTS_CAPTURE_FRAMES {
		h.settle = 1
		host.host_frame(h)
		p, s, status := render.capture_poll(&app.shared.r)
		#partial switch status {
		case .Ready: return p, s, true
		case .Failed, .None: return
		}
	}
	return
}
