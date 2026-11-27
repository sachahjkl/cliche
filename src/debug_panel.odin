package cliche

// cliche's state in the toolkit's debug window (Ctrl+Alt+Shift+D in a build with the devtools):
// src/md/features/debug-panel.md. A release build compiles every debug call away.

import "gt:debug"
import host "gt:host"

DEBUG_PANEL :: "Cliche"

// Once the main window is open: its data is the App, which outlives the window's State.
debug_panel_register :: proc(app: ^App, h: ^host.Host) {
	debug.panel(&h.state, DEBUG_PANEL, debug_panel_build, app)
}

// (a test registers the same procedure on its own window)
debug_panel_build_for_test :: debug_panel_build

@(private = "file")
debug_panel_build :: proc(app: ^App) {
	if debug.section("Capture") {
		debug.watch("flow", app.flow)
		debug.watch("use", app.capture_use)
		debug.watch("target", app.capture_target)
		debug.watch("backend", app.backend)
		debug.watch("desktop read", app.has_desktop)
		if app.has_desktop {
			d := &app.desktop
			for o in d.outputs { debug.watch(o.name, [?]any{o.rect, o.scale}) }
			debug.watch("windows", len(d.windows))
			debug.watch("window rects", d.have_rects)
		}
		if app.has_last_region { debug.watch("last region", app.last_region) }
	}
	if debug.section("Overlay") {
		o := &app.overlay
		debug.watch("visible", o.visible)
		debug.watch("placed", o.placed)
		debug.watch("mode", o.mode)
		for w, i in o.windows { debug.watch(i == 0 ? "windows" : "", [?]any{w.out, w.host.win != nil ? w.host.win.dpi_scale : 0, w.visible}) }
		if o.has_pointer { debug.watch("pointer", o.pointer) }
		if o.sel.has_rect { debug.watch("selection", o.sel.rect) }
		debug.watch("dragging", o.sel.dragging)
		debug.watch("decision", o.decision)
	}
	if debug.section("Recording") {
		debug.watch("state", app.record)
		debug.watch("region", app.record_region)
		debug.watch("output", app.record_output)
		debug.watch("recorder runs", app.recorder.thread != nil)
	}
	if debug.section("Workflows") {
		debug.watch("workflows", len(app.workflows.set.list))
		debug.watch("loaded", app.workflows_loaded)
		if app.workflows_problem != "" { debug.watch("problem", app.workflows_problem) }
		debug.watch("runs in flight", len(app.runs))
	}
	if debug.section("Windows") {
		debug.watch("editors", len(app.editors))
		debug.watch("pins", len(app.pins))
	}
	// (tried, not saved: the next read of the preferences sets them back)
	if debug.section("Region") {
		s := &app.settings
		debug.toggle("magnifier", &s.magnifier)
		debug.number("dim", &s.dim, lo = 0, hi = 1, step = 0.05)
		debug.toggle("frame windows", &s.frame_windows)
		debug.toggle("confirm on release", &s.confirm_on_release)
	}
	if debug.act("Region") { app_trigger(app, .Region) }
	if debug.act("Colour") { app_color_pick(app) }
	if debug.act("Ruler") { app_ruler(app) }
	if debug.act("Record") { app_record_trigger(app, .Mp4) }
}
