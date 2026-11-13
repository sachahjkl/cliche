package cliche

// The record overlay: while a recording is ready or runs, a window over every other one on the output of its region
// (gt:host's overlay: a layer surface on Wayland, a topmost window elsewhere), transparent but for two things:
//   - a frame around the region, drawn outside it (what is inside is recorded): the theme's accent while ready, red
//     while recording;
//   - a bar of buttons outside the region (below it, else above it, else inside its bottom edge when the region is the
//     whole output): Record, the format and Cancel while ready; the time, Stop and Cancel while recording.
// Only the bar takes the pointer (platform.set_input_region): the rest of the screen stays usable. A click on the bar
// gives the window the keyboard: Escape then cancels a recording not started.
//
// Opened at Ready, closed at the end (record_app.odin). Its decisions are acted on after its frame, as the region's
// overlay does.

import "core:fmt"
import "core:math"
import "gt:draw"
import "gt:font"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"
import i18n "gt:i18n"

RECORD_FRAME_PX :: 2   // the frame's width, logical pixels

// The bar's width, in ems: while ready (Record, the format, Cancel), while recording (the time, Stop, Cancel).
@(private = "file") RECORD_BAR_READY_EM   :: 18.5
@(private = "file") RECORD_BAR_RUNNING_EM :: 13

Record_Overlay_Decision :: enum u8 { None, Start, Stop, Cancel }

Record_Overlay :: struct {
	host:        host.Host,
	opened:      bool,
	visible:     bool,
	area:        Rect,           // the output it covers, logical
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
	decision:    Record_Overlay_Decision,
	bar:         [4]int,         // the bar as the last build placed it: x, y, width, height, logical, in the window
	bar_set:     [4]int,         // the input region given to the system last
}

// Opens the overlay over the region's output (app.record_output) and shows it. False: no overlay here (no layer shell).
record_overlay_show :: proc(app: ^App, headless := false) -> bool {
	ro := &app.record_overlay
	out := app.record_output
	// (another output than the last one: a window of the system covers one output, the one it was opened on)
	if ro.opened && ro.area != out { record_overlay_close(app) }
	if !ro.opened {
		area := [4]int{int(out.x), int(out.y), int(out.w), int(out.h)}
		// (headless: offscreen, on the software renderer: clichetool shots)
		o := host.Open{title = "cliche recording", size = {max(area[2], 1), max(area[3], 1)}, overlay = !headless, overlay_area = area, headless = headless}
		if !host.host_open(&ro.host, &app.shared, o, record_overlay_build, app) { return false }
		ro.host.close_asked = proc(h: ^host.Host) { (^App)(h.user).record_overlay.decision = .Cancel }
		ro.opened = true
		app_standard_follow(app, &ro.host)
		ro.area = out
		ro.host.params = record_overlay_params
		ro.host.after_input = 2
		if ro.icons == 0 { ro.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA) }
		ro.host.state.icon_font = ro.icons
		app_wake_add(app, ro.host.win)
	}
	ro.decision = .None
	ro.bar, ro.bar_set = {}, {}
	// (no pointer anywhere until the first build places the bar: the screen stays usable from the start)
	platform.set_input_region(ro.host.win, nil)
	if !ro.visible {
		host.host_show(&ro.host)
		ro.visible = true
	}
	ro.host.settle = max(ro.host.settle, 3)
	return true
}

// The recording is over: the window goes. The renderer's own window (the first one cliche opened) is only hidden: the
// others need the renderer.
record_overlay_close :: proc(app: ^App) {
	ro := &app.record_overlay
	if !ro.opened { return }
	ro.decision = .None
	if app.shared.main == &ro.host {
		if ro.visible { host.host_hide(&ro.host) }
		ro.visible = false
		return
	}
	// (no other thread wakes a window about to go)
	app_wake_remove(app, ro.host.win)
	app_host_close(app, &ro.host)
	ro.opened, ro.visible = false, false
}

// A frame is owed: the recording's state or time changed.
record_overlay_redraw :: proc(app: ^App) {
	ro := &app.record_overlay
	if ro.visible { ro.host.settle = max(ro.host.settle, 2) }
}

// After the frame: the input region follows the bar; the decision is acted on.
record_overlay_after_frame :: proc(app: ^App) {
	ro := &app.record_overlay
	if ro.bar != ro.bar_set && ro.bar[2] > 0 && ro.bar[3] > 0 {
		rects := [1][4]int{ro.bar}
		platform.set_input_region(ro.host.win, rects[:])
		ro.bar_set = ro.bar
	}
	decision := ro.decision
	ro.decision = .None
	switch decision {
	case .None:
	case .Start:  app_record_start(app)
	case .Stop:   app_record_stop(app)
	case .Cancel: app_record_cancel(app)
	}
}

// Where the bar goes, in the window's pixels: centred under the region, else over it, else inside its bottom edge;
// always inside the window. `region`: x, y, width, height in the window; `gap`: between the region and the bar.
record_bar_place :: proc(region: [4]f32, window, bar: [2]f32, gap: f32) -> [2]f32 {
	x := region.x + (region.z - bar.x) / 2
	x = clamp(x, 0, max(window.x - bar.x, 0))
	below := region.y + region.w + gap
	above := region.y - gap - bar.y
	y: f32
	switch {
	case below + bar.y <= window.y: y = below
	case above >= 0:                y = above
	case:                           y = min(region.y + region.w, window.y) - gap - bar.y
	}
	return {x, max(y, 0)}
}

// Each build: the theme of the main window.
@(private = "file")
record_overlay_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	app := (^App)(h.user)
	ro := &app.record_overlay
	a := app.settings.appearance
	choice := prefs_page.appearance_choice(a)
	choice.glow = 1
	ui.theme_show(&app.shared.theme, app.themes_file.all[:], choice, &ro.theme_shown, render.blend_space(&app.shared.r))
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
}

@(private = "file")
Record_Frame_Draw :: struct { rect: draw.Rect, width: f32, color: draw.Color }

@(private = "file")
record_overlay_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	ro := &app.record_overlay
	em := ui.font_size()
	s := max(ui.scale(), 0.01)
	ready := record_ready(app.record)
	if ready && ui.key_press(.Escape) { ro.decision = .Cancel }

	r := app.record_region
	region := [4]f32{f32(r.x - ro.area.x) * s, f32(r.y - ro.area.y) * s, f32(r.w) * s, f32(r.h) * s}
	width := max(math.round(RECORD_FRAME_PX * s), 1)
	d := ui.frame_new(Record_Frame_Draw)
	// (an outline is drawn inside its rectangle: grown by its width, it lies all outside the region)
	d^ = {rect = {{region.x - width, region.y - width}, {region.x + region.z + width, region.y + region.w + width}}, width = width, color = ready ? ui.color("accent") : ui.color("bad text")}
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(size.x), height = ui.px(size.y)})
	ui.custom("###frame", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Record_Frame_Draw)(user)
		draw.rect(dc, d.rect, d.color, 0, d.width)
	}, d)

	side := math.round(em * 2.2)
	bar := [2]f32{math.round(em * (ready ? RECORD_BAR_READY_EM : RECORD_BAR_RUNNING_EM)), side + math.round(em * 0.8)}
	at := record_bar_place(region, {size.x, size.y}, bar, width + math.round(em * 0.5))
	ui.next({fixed_x = at.x, fixed_y = at.y, width = ui.px(bar.x), height = ui.px(bar.y), axis = .X, cross = .Center, radius = math.round(em * 0.6)})
	box := ui.build_box({.Draw_Background, .Draw_Border}, "###bar")
	if ui.parent(box) {
		ui.spacer(ui.px(em * 0.5))
		if ready { record_bar_ready(app, em, side) } else { record_bar_running(app, em, side) }
		ui.spacer(ui.px(em * 0.5))
	}
	ro.bar = {int(at.x / s), int(at.y / s), int(math.ceil(bar.x / s)), int(math.ceil(bar.y / s))}
}

// While ready: Record (red, a dot and its word), the format, Cancel.
@(private = "file")
record_bar_ready :: proc(app: ^App, em, side: f32) {
	ro := &app.record_overlay
	format := record_format(app.record)
	keys := app.tray_keys[format == .Gif ? .Record_Gif : .Record]
	ui.next({width = ui.px(math.round(em * 6.6)), height = ui.px(side), radius = math.round(em * 0.4), axis = .X, cross = .Center})
	sig: ui.Signal
	// (ui.button's look, with a dot before its word: the toolkit's button holds words only)
	if ui.tags(ui.intent_tag(.Danger)) {
		if ui.tags("button") {
			b := ui.build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects}, "###record")
			sig = ui.signal(b)
			if ui.parent(b) {
				ui.spacer(ui.px(math.round(em * 0.75)))
				ui.dot("###record_dot", math.round(em * 0.7))   // (the button's words' colour)
				ui.spacer(ui.px(math.round(em * 0.45)))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###record_label", i18n.tr("record button", "Record")))
			}
		}
	}
	if sig.clicked { ro.decision = .Start }
	if ui.hovered_for(sig) {
		if ui.tooltip() { ui.tooltip_text(keys != "" ? fmt.tprintf(i18n.tr("Start recording (%s)"), keys) : i18n.tr("Start recording")) }
	}
	ui.spacer(ui.px(math.round(em * 0.6)))
	@(static, rodata) labels := [2]string{"MP4", "GIF"}
	tips := [2]string{i18n.tr("A video (H.264)"), i18n.tr("An animated GIF")}
	at := int(format)
	ui.next({width = ui.px(math.round(em * 7)), height = ui.px(math.round(side * 0.85))})
	if ui.segmented("###format", labels[:], &at, tips[:]) { app_record_step(app, Record_Format_Set{Record_Format(at)}) }
	ui.spacer(ui.fill())
	if record_icon("cancel", lucide.X, i18n.tr("Cancel (Escape)"), side) { ro.decision = .Cancel }
}

// While recording: a red dot, the time, Stop, Cancel (the file deleted).
@(private = "file")
record_bar_running :: proc(app: ^App, em, side: f32) {
	ro := &app.record_overlay
	keys := app.tray_keys[record_format(app.record) == .Gif ? .Record_Gif : .Record]
	text := i18n.tr("Starting…")
	can := true
	#partial switch v in app.record {
	case Record_Recording:  text = record_clock_text(v.elapsed_ms)
	case Record_Stopping:   text, can = i18n.tr("Saving…"), false
	case Record_Discarding: text, can = i18n.tr("Deleting…"), false
	}
	ui.dot("###live_dot", math.round(em * 0.75), .Danger)
	ui.spacer(ui.px(math.round(em * 0.5)))
	ui.next({width = ui.px(math.round(em * 5.5)), height = ui.pct(1), text_pad = 0, font = ui.mono_font()})
	ui.label(fmt.tprintf("%s###clock", text))
	ui.spacer(ui.fill())
	if record_icon("stop", lucide.SQUARE, keys != "" ? fmt.tprintf(i18n.tr("Stop and save (%s)"), keys) : i18n.tr("Stop and save"), side, can) { ro.decision = .Stop }
	if record_icon("discard", lucide.X, i18n.tr("Cancel: the recording is deleted"), side, can) { ro.decision = .Cancel }
}

// An icon button of the bar, as the editor's bar draws them.
@(private = "file")
record_icon :: proc(id, glyph, tip: string, side: f32, enabled := true) -> bool {
	ui.next({width = ui.px(side), height = ui.px(side), radius = math.round(side * 0.22), font_size = math.round(side * 0.5)})
	return ui.icon_button(id, glyph, tip = tip, disabled = !enabled).clicked && enabled
}
