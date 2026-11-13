package cliche

// The recording in the running cliche. A command, the tray or a shortcut asks for one; its region is chosen on the
// frozen desktop as a screenshot's. Then nothing records yet: the record overlay (record_overlay.odin) frames the
// region over the other programs, with a Record button. The user starts the recording there, or with the same keys, or
// with a click on the tray's icon; the same again stops it. Cancel before the start gives it up; Cancel while it runs
// deletes its file. The recorder's messages (record.odin) are shown by the overlay and the tray, and the end by a
// notification.
//
// Where no overlay can open (a desktop with no layer shell), the recording starts at once, and a notification says how
// to stop it.

import "core:fmt"
import "core:log"
import capture "gt:capture"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

// `cliche --record`, `--record-gif`, their shortcuts: a region to choose; again, the recording starts; again, it stops.
app_record_trigger :: proc(app: ^App, format: Record_Format) {
	#partial switch _ in app.record {
	case Record_Ready:
		app_record_start(app)
		return
	case Record_Starting, Record_Recording:
		app_record_stop(app)
		return
	}
	if record_busy(app.record) { return }   // (its region being chosen, or its end being written)
	if !app_record_step(app, Record_Trigger{format}) { return }
	if !app_capture_start(app, .Region, .Region, record = true) {
		// (a screenshot is being taken: the recording waits for none)
		app_record_step(app, Record_Cancelled{})
	}
}

app_record_step :: proc(app: ^App, e: Record_Event) -> bool {
	next, ok := record_step(app.record, e)
	if ok { app.record = next }
	return ok
}

// The rectangle chosen: the capture flow is done with the frozen desktop. The recording is Ready: the overlay frames
// the region on the live screen and waits for Record.
app_record_chosen :: proc(app: ^App, r: Rect) {
	app_step(app, Flow_Cancelled{})
	app.record_output = app.overlay.out   // (the region's overlay covered the output the rectangle is on)
	app_desktop_drop(app)
	if !app_record_step(app, Record_Chosen{}) { return }
	app.record_region = r
	app_tray_menu(app)
	if record_overlay_show(app) { return }
	app_record_start(app)
	if !record_running(app.record) || !app.settings.record_notify { return }
	keys := app.tray_keys[record_format(app.record) == .Gif ? .Record_Gif : .Record]
	body := keys != "" ? fmt.tprintf(i18n.tr("Press %s again, or click cliche's icon, to stop it."), keys) : i18n.tr("Click cliche's icon in the notification area to stop it.")
	app_announce(app, .Info, i18n.tr("Recording"), body)
}

// The Record button, the same keys, the tray: the recorder starts on the live screen.
app_record_start :: proc(app: ^App) {
	if !app_record_step(app, Record_Start{}) { return }
	s := &app.settings
	job := Record_Job{
		format = record_format(app.record), source = capture.Stream_Region{app.record_region}, kind = .Region,
		fps = s.record_fps, gif_fps = s.gif_fps, gif_width = s.gif_width, cursor = s.record_cursor,
		max_ms = i64(s.record_max_s) * 1000, folder = clone_string(s.folder), pattern = clone_string(s.name_pattern),
	}
	app_tray_icon(app, recording = true)
	app_tray_menu(app)
	record_overlay_redraw(app)
	if !recorder_start(&app.recorder, job, app_wake, app) {
		app_record_step(app, Record_Fail{.Failed})
		app_record_end(app)
		app_record_told(app, "", 0, 0)
	}
}

// The Stop button, the same keys, the tray: the recorder writes its file and ends.
app_record_stop :: proc(app: ^App) {
	if app_record_step(app, Record_Stop{}) {
		recorder_stop(&app.recorder)
		record_overlay_redraw(app)
	}
}

// Cancel: before the start, the recording is given up; while it runs, its file is deleted. Nothing is told.
app_record_cancel :: proc(app: ^App) {
	#partial switch _ in app.record {
	case Record_Ready:
		app_record_step(app, Record_Cancelled{})
		app_record_end(app)
	case Record_Starting, Record_Recording:
		if app_record_step(app, Record_Discard{}) {
			recorder_cancel(&app.recorder)
			record_overlay_redraw(app)
		}
	}
}

// The region's overlay gave up, or the desktop could not be read: no recording.
app_record_abandoned :: proc(app: ^App, failed: bool) {
	if _, choosing := app.record.(Record_Choosing); !choosing { return }
	if failed {
		app_record_step(app, Record_Fail{.Failed})
		app_record_told(app, "", 0, 0)
	} else {
		app_record_step(app, Record_Cancelled{})
	}
}

// The recorder's messages, in order.
app_record_messages :: proc(app: ^App) {
	for m in recorder_take(&app.recorder) {
		m := m
		defer record_message_free(&m)
		switch v in m {
		case Record_Opened:
			app_record_step(app, Record_Started{})
			record_overlay_redraw(app)
		case Record_Tick:
			app_record_step(app, Record_Progress{v.elapsed_ms})
			if app.tray != nil { platform.tray_set_tooltip(app.tray, fmt.tprintf(i18n.tr("cliche: recording, %s"), record_clock_text(v.elapsed_ms))) }
			record_overlay_redraw(app)
		case Record_Ended:
			_, discarding := app.record.(Record_Discarding)
			if v.error == .None { app_record_step(app, Record_Finished{}) } else { app_record_step(app, Record_Fail{v.error}) }
			recorder_join(&app.recorder)
			app_record_end(app)
			if discarding { continue }   // (the file is deleted: nothing to tell)
			app_record_told(app, v.path, v.bytes, v.length_ms)
			if v.error == .None && v.path != "" && app.settings.record_reveal { ui.open(v.path, .Reveal) }
		}
	}
}

// The recording is over or given up: the overlay goes, the tray is as at rest.
@(private = "file")
app_record_end :: proc(app: ^App) {
	record_overlay_close(app)
	app_tray_icon(app, recording = false)
	if app.tray != nil { platform.tray_set_tooltip(app.tray, "cliche") }
	app_tray_menu(app)
}

// Done or Failed: told to the user, then Idle.
app_record_told :: proc(app: ^App, path: string, bytes, length_ms: i64) {
	title, body: string
	failed := false
	#partial switch s in app.record {
	case Record_Done:
		title = s.format == .Gif ? i18n.tr("GIF saved") : i18n.tr("Recording saved")
		size := [2]int{int(app.record_region.w), int(app.record_region.h)}
		app.notice_entry = history_note(app, {kind = s.format == .Gif ? .Gif : .Video, path = path, size = size, bytes = bytes, length_ms = length_ms})
		body = record_notice_body(path, bytes, length_ms)
	case Record_Failed:
		title, body = i18n.tr("No recording"), i18n.tr(RECORD_ERROR_TEXT[s.error])
		failed = true
		log.warn(body)
	}
	if title != "" && (app.settings.record_notify || failed) { app_announce(app, failed ? .Bad : .Good, title, body) }
	app_record_step(app, Record_Reset{})
}

@(private = "file")
clone_string :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}
