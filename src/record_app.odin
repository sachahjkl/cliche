package cliche

// The recording in the running cliche: what starts it (a command, the tray, a shortcut), the region chosen on the frozen
// desktop as a screenshot's, the recorder's messages (record.odin) told by the tray, and the notification at the end.
// The same command, or the tray, stops it.

import "core:fmt"
import capture "gt:capture"
import "gt:platform"

// `cliche --record`, `--record-gif`: a recording starts (its region chosen first), or the one running stops.
app_record_trigger :: proc(app: ^App, format: Record_Format) {
	if record_running(app.record) {
		if app_record_step(app, Record_Stop{}) { recorder_stop(&app.recorder) }
		return
	}
	if !app_record_step(app, Record_Trigger{format}) { return }
	if !app_trigger(app, .Region, .Record) {
		// (a screenshot is being taken: the recording waits for none)
		app_record_step(app, Record_Cancelled{})
	}
}

app_record_step :: proc(app: ^App, e: Record_Event) -> bool {
	next, ok := record_step(app.record, e)
	if ok { app.record = next }
	return ok
}

// The rectangle chosen: the capture flow is done with the frozen desktop, the recorder starts on the live screen.
app_record_chosen :: proc(app: ^App, r: Rect) {
	app_step(app, Flow_Cancelled{})
	app_desktop_drop(app)
	format := Record_Format.Mp4
	if c, choosing := app.record.(Record_Choosing); choosing { format = c.format }
	if !app_record_step(app, Record_Chosen{}) { return }
	app.record_size = {int(r.w), int(r.h)}
	s := &app.settings
	job := Record_Job{
		format = format, source = capture.Stream_Region{r}, kind = .Region,
		fps = s.record_fps, gif_fps = s.gif_fps, gif_width = s.gif_width, cursor = s.record_cursor,
		max_ms = i64(s.record_max_s) * 1000, folder = clone_string(s.folder), pattern = clone_string(s.name_pattern),
	}
	if !recorder_start(&app.recorder, job, app_wake, app) {
		app_record_step(app, Record_Fail{.Failed})
		app_record_told(app, "", 0, 0)
	}
}

// The overlay gave up, or the desktop could not be read: no recording.
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
			app_tray_recording(app, true)
		case Record_Tick:
			app_record_step(app, Record_Progress{v.elapsed_ms})
			if app.tray != nil { platform.tray_set_tooltip(app.tray, fmt.tprintf("cliche: recording, %s", record_elapsed_text(v.elapsed_ms))) }
		case Record_Ended:
			if v.error == .None { app_record_step(app, Record_Finished{}) } else { app_record_step(app, Record_Fail{v.error}) }
			recorder_join(&app.recorder)
			app_tray_recording(app, false)
			app_record_told(app, v.path, v.bytes, v.length_ms)
			if v.error == .None && v.path != "" && app.settings.reveal { worker_send(&app.worker, Job_Reveal{path = clone_string(v.path)}) }
		}
	}
}

// Done or Failed: told to the user, then Idle.
app_record_told :: proc(app: ^App, path: string, bytes, length_ms: i64) {
	title, body: string
	#partial switch s in app.record {
	case Record_Done:
		title = s.format == .Gif ? "GIF saved" : "Recording saved"
		app.notice_entry = history_note(app, {kind = s.format == .Gif ? .Gif : .Video, path = path, size = app.record_size, bytes = bytes, length_ms = length_ms})
		body = record_notice_body(path, bytes, length_ms)
	case Record_Failed:
		title, body = "No recording", RECORD_ERROR_TEXT[s.error]
		fmt.eprintfln("cliche: %s", body)
	}
	if title != "" && app.settings.notify {
		if id, ok := platform.notify(app.anchor, {title = title, body = body, silent = true, replace = app.notice}); ok { app.notice = id }
	}
	app_record_step(app, Record_Reset{})
}

// The tray while a recording runs: "Stop recording" first, a click stops it; then the menu as it was.
app_tray_recording :: proc(app: ^App, on: bool) {
	if app.tray == nil { return }
	if on {
		platform.tray_set_menu(app.tray, {
			{id = int(Tray_Item.Record), text = "Stop recording", default = true},
			{kind = .Separator},
			{id = int(Tray_Item.History), text = "History"},
			{id = int(Tray_Item.Settings), text = "Settings"},
			{id = int(Tray_Item.Quit), text = "Quit cliche"},
		})
		platform.tray_set_tooltip(app.tray, "cliche: recording")
	} else {
		app_tray_menu(app)
		platform.tray_set_tooltip(app.tray, "cliche")
	}
}

@(private = "file")
clone_string :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}
