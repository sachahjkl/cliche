package cliche

// The running cliche: one process for the session, in the notification area. What it holds at rest is small: a window
// that is never shown (the anchor: the tray icon, the notifications, the hotkeys and the clipboard are a window's), the
// worker's thread with the capture session, and the thread that hears other starts. The renderer is made at the first
// window that needs one (the overlay of a region, the settings), and that window is then hidden, not closed, so that it
// comes back at once.
//
// The loop, on the interface's thread:
//   wait     the shown windows' frames (host.hosts_wait), or the anchor alone when none is shown
//   read     the anchor's events (hotkeys), the commands of other starts, the tray, the worker's results
//   frames   a frame of each shown window
// Every other thread wakes it through app_wake: the waits end on a wake of any of the windows.

import "core:fmt"
import "core:strings"
import "core:sync"
import capture "gt:capture"
import config "gt:config"
import "gt:host"
import instance "gt:instance"
import "gt:platform"
import "gt:render"

// The tray menu's items.
Tray_Item :: enum { None, Region, Screen, Window, Qr, Settings, Quit }

// A command another start handed over (token owned).
Inbox_Item :: struct { verb: Verb, token: string }

// The windows other threads wake.
Window_Slot :: enum u8 { Anchor, Overlay, Settings }

App :: struct {
	prefs:      config.Prefs,
	settings:   Settings,
	anchor:     ^platform.Window,
	tray:       ^platform.Tray,
	server:     ^instance.Server,
	worker:     Worker,
	inbox_lock: sync.Mutex,
	inbox:      [dynamic]Inbox_Item,                       // guarded by `inbox_lock`
	wakes:      [Window_Slot]^platform.Window,             // atomic: written by this thread, read by the others
	shared:     host.Shared,                               // the renderer, from the first window that needs it
	overlay:    Overlay,                                   // overlay.odin
	settings_window: Settings_Window,                      // settings_view.odin

	flow:       Flow,                                      // flow.odin
	desktop:    Result_Desktop,                            // the region's desktop, from Selecting to its cut (owned)
	has_desktop: bool,
	copied:     bool,                                      // the shot of this capture went to the clipboard
	purpose:    Purpose,                                   // what this capture is for (actions.odin)
	token:      string,                                    // the activation token of the next window shown (owned)
	backend:    capture.Backend,                           // the session's, once open
	notice:     platform.Notification_Id,                  // the last notification: the next one replaces it
	hotkeys:    Hotkeys,                                   // hotkeys_*.odin
	quit:       bool,
}

app_run :: proc(prefs: ^config.Prefs, owner: instance.Owner, first: Command) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)
	app.flow = Flow_Idle{}

	platform.set_app_id(APP_NAME)
	platform.notify_set_app({name = "cliche"})
	app.anchor = platform.open_window("cliche", {1, 1})
	if app.anchor == nil {
		fmt.eprintln("cliche: no window can be opened here")
		app_free(app)
		return 1
	}
	app_wake_set(app, .Anchor, app.anchor)
	if !worker_start(&app.worker, app_wake, app) {
		fmt.eprintln("cliche: the worker's thread cannot start")
		platform.destroy_window(app.anchor)
		app_free(app)
		return 1
	}
	// (opened now, on the worker: the first capture does not wait for the compositor's protocols)
	worker_send(&app.worker, Job_Open{})
	app.server = instance.serve_start(owner, app_message, app)
	app_tray_open(app)
	app_hotkeys(app)
	app_command(app, first.verb, first.token)

	for !app.quit {
		app_wait(app)
		app_anchor_events(app)
		app_inbox(app)
		app_tray(app)
		app_results(app)
		app_frames(app)
	}

	instance.serve_stop(app.server)
	worker_stop(&app.worker)   // (before the desktop goes: a cut may be reading it)
	if app.has_desktop { desktop_free(&app.desktop) }
	app_windows_close(app)
	platform.destroy_window(app.anchor)   // (its tray icon with it)
	app_free(app)
	return 0
}

@(private = "file")
app_free :: proc(app: ^App) {
	for item in app.inbox { delete(item.token) }
	delete(app.inbox)
	delete(app.token)
	hotkeys_free(&app.hotkeys)
	settings_free(&app.settings)
	config.prefs_destroy(&app.prefs)
}

// The shown windows' frames, else the anchor: what ends the wait is a wake of any window (app_wake), input, the tray.
@(private = "file")
app_wait :: proc(app: ^App) {
	shown := make([dynamic]^host.Host, 0, 2, context.temp_allocator)
	if app.overlay.visible { append(&shown, &app.overlay.host) }
	if app.settings_window.visible { append(&shown, &app.settings_window.host) }
	if len(shown) > 0 { host.hosts_wait(shown[:]) } else { platform.wait_event(app.anchor, 0) }
}

@(private = "file")
app_frames :: proc(app: ^App) {
	if app.overlay.visible {
		overlay_prepare(app)
		host.host_frame(&app.overlay.host)
		overlay_after_frame(app)
	}
	if app.settings_window.visible {
		host.host_frame(&app.settings_window.host)
		settings_after_frame(app)
	}
}

// The windows with a renderer close in the order the host asks: the renderer's own window last.
@(private = "file")
app_windows_close :: proc(app: ^App) {
	overlay_destroy(app)
	hosts := [2]^host.Host{&app.overlay.host, &app.settings_window.host}
	opened := [2]bool{app.overlay.opened, app.settings_window.opened}
	for h, i in hosts { if opened[i] && app.shared.main != h { host.host_close(h) } }
	for h, i in hosts { if opened[i] && app.shared.main == h { host.host_close(h) } }
	settings_window_free(app)
}

// Wakes the interface's loop, from any thread.
app_wake :: proc(user: rawptr) {
	app := (^App)(user)
	for slot in Window_Slot {
		if w := sync.atomic_load(&app.wakes[slot]); w != nil { platform.wake(w) }
	}
}

app_wake_set :: proc(app: ^App, slot: Window_Slot, w: ^platform.Window) {
	sync.atomic_store(&app.wakes[slot], w)
}

// A message of another start, on the instance's thread: queued for the interface's.
@(private = "file")
app_message :: proc(user: rawptr, message: []byte) {
	app := (^App)(user)
	c, ok := command_parse(string(message))
	if !ok { return }
	sync.mutex_lock(&app.inbox_lock)
	append(&app.inbox, Inbox_Item{c.verb, strings.clone(c.token)})
	sync.mutex_unlock(&app.inbox_lock)
	app_wake(app)
}

@(private = "file")
app_inbox :: proc(app: ^App) {
	sync.mutex_lock(&app.inbox_lock)
	items := make([]Inbox_Item, len(app.inbox), context.temp_allocator)
	copy(items, app.inbox[:])
	clear(&app.inbox)
	sync.mutex_unlock(&app.inbox_lock)
	for item in items {
		app_command(app, item.verb, item.token)
		delete(item.token)
	}
}

// Runs a command (`token` is not kept: a copy is).
app_command :: proc(app: ^App, verb: Verb, token: string) {
	if token != "" {
		delete(app.token)
		app.token = strings.clone(token)
	}
	switch verb {
	case .Ping:
	case .Region:   app_trigger(app, .Region)
	case .Screen:   app_trigger(app, .Screen)
	case .Window:   app_trigger(app, .Window)
	case .Qr:       app_trigger(app, .Region, .Qr)
	case .Settings: settings_window_show(app)
	case .Quit:     app.quit = true
	}
}

// The activation token for a window shown now ("" none; the caller owns it).
app_take_token :: proc(app: ^App) -> string {
	t := app.token
	app.token = ""
	return t
}

// Applies a flow event. False: it means nothing in the current state.
app_step :: proc(app: ^App, e: Flow_Event) -> bool {
	next, ok := flow_step(app.flow, e)
	if ok { app.flow = next }
	return ok
}

app_trigger :: proc(app: ^App, source: Source, purpose := Purpose.Picture) {
	if !app_step(app, Flow_Trigger{source}) { return }   // (one capture at a time)
	app.copied = false
	app.purpose = purpose
	// (the renderer's device made while the desktop is read: the overlay's first show does not wait for the driver)
	if source == .Region && app.shared.main == nil && render.device_preload_state() == .Not_Started { render.preload_device() }
	worker_send(&app.worker, Job_Grab{source})
}

// The worker's results, in order.
@(private = "file")
app_results :: proc(app: ^App) {
	for r in worker_take(&app.worker) {
		switch v in r {
		case Result_Opened:
			app.backend = v.backend
			if v.error != .None { fmt.eprintfln("cliche: no capture here: %s", FLOW_ERROR_TEXT[flow_error_of(v.error)]) }
		case Result_Desktop:
			app_desktop(app, v)
		case Result_Shot:
			app_shot(app, v)
		case Result_Saved:
			app_saved(app, v)
		case Result_Written:
			if !v.ok { fmt.eprintfln("cliche: %s cannot be written", v.path) }
			delete(v.path)
		case Result_Qr:
			app_qr(app, v)
		}
	}
}

@(private = "file")
app_desktop :: proc(app: ^App, d: Result_Desktop) {
	d := d
	if _, capturing := app.flow.(Flow_Capturing); !capturing {
		desktop_free(&d)
		return
	}
	if d.error != .None {
		desktop_free(&d)
		app_step(app, Flow_Capture_Failed{flow_error_of(d.error)})
		app_outcome(app, "")
		return
	}
	app.desktop, app.has_desktop = d, true
	app_step(app, Flow_Captured{})
	if !overlay_show(app) {
		app_desktop_drop(app)
		app_step(app, Flow_Capture_Failed{.Failed})
		app_outcome(app, "")
	}
}

app_desktop_drop :: proc(app: ^App) {
	if app.has_desktop { desktop_free(&app.desktop) }
	app.has_desktop = false
}

// What the overlay decided, after its frame.
app_region_confirmed :: proc(app: ^App, r: Rect) {
	if !app_step(app, Flow_Confirmed{}) { return }
	overlay_hide(app)
	// (the desktop stays until the cut comes back: the worker reads it)
	worker_send(&app.worker, Job_Crop{app.desktop.frame, r})
}

app_region_cancelled :: proc(app: ^App) {
	app_step(app, Flow_Cancelled{})
	overlay_hide(app)
	app_desktop_drop(app)
}

@(private = "file")
app_shot :: proc(app: ^App, r: Result_Shot) {
	r := r
	#partial switch s in app.flow {
	case Flow_Capturing:
		if r.error != .None {
			app_step(app, Flow_Capture_Failed{r.error})
			app_outcome(app, "")
			return
		}
		app_step(app, Flow_Captured{})
		app_chain(app, r.shot)
	case Flow_Encoding:
		if s.source == .Region { app_desktop_drop(app) }
		if r.error != .None {
			shot_free(&r.shot)
			app_step(app, Flow_Save_Failed{r.error})
			app_outcome(app, "")
			return
		}
		app_chain(app, r.shot)
	case:
		shot_free(&r.shot)
	}
}

// The action chain: the clipboard here (it is the window's thread's), the file on the worker. The shot goes with the job.
@(private = "file")
app_chain :: proc(app: ^App, shot: Shot) {
	if app.purpose == .Qr {
		worker_send(&app.worker, Job_Qr{shot})
		return
	}
	actions := app.settings.actions & AFTER_CAPTURE_DONE
	if .Copy in actions {
		// (gt:platform encodes the clipboard's PNG on this thread, at its fast level: it takes no encoded file)
		app.copied = platform.clipboard_set_image(app.anchor, {rgba = shot.rgba, size = shot.size})
		if !app.copied { fmt.eprintln("cliche: the picture cannot go to the clipboard") }
	}
	worker_send(&app.worker, Job_Save{
		shot = shot, folder = strings.clone(app.settings.folder), pattern = strings.clone(app.settings.name_pattern),
		save = .Save in actions,
	})
}

@(private = "file")
app_saved :: proc(app: ^App, r: Result_Saved) {
	defer delete(r.path)
	if _, encoding := app.flow.(Flow_Encoding); !encoding { return }
	if r.error != .None { app_step(app, Flow_Save_Failed{r.error}) } else { app_step(app, Flow_Saved{}) }
	app_outcome(app, r.path)
}

// The QR code's text, read: on the clipboard.
@(private = "file")
app_qr :: proc(app: ^App, r: Result_Qr) {
	defer delete(r.text)
	if _, encoding := app.flow.(Flow_Encoding); !encoding { return }
	if r.error != .None {
		app_step(app, Flow_Save_Failed{r.error})
		app_outcome(app, "")
		return
	}
	app.copied = platform.clipboard_set(app.anchor, {text = r.text})
	if !app.copied { fmt.eprintln("cliche: the QR code's text cannot go to the clipboard") }
	app_step(app, Flow_Saved{})
	app_outcome(app, r.text)
}

// Done or Failed: told to the user, then Idle. `detail`: the file saved, or the QR code's text.
@(private = "file")
app_outcome :: proc(app: ^App, detail: string) {
	path := detail
	title, body: string
	#partial switch s in app.flow {
	case Flow_Done:
		switch {
		case app.purpose == .Qr && app.copied: title, body = "QR code copied", notice_text(detail)
		case app.purpose == .Qr:               title, body = "QR code read", notice_text(detail)
		case path != "" && app.copied: title, body = "Screenshot saved and copied", path
		case path != "":               title, body = "Screenshot saved", path
		case app.copied:               title, body = "Screenshot copied to the clipboard", ""
		}
	case Flow_Failed:
		title, body = app.purpose == .Qr ? "No QR code" : "No screenshot", FLOW_ERROR_TEXT[s.error]
		fmt.eprintfln("cliche: %s", body)
	}
	if title != "" && app.settings.notify {
		if id, ok := platform.notify(app.anchor, {title = title, body = body, silent = true, replace = app.notice}); ok { app.notice = id }
	}
	app_step(app, Flow_Reset{})
}

// The anchor's events: the hotkeys (Windows).
@(private = "file")
app_anchor_events :: proc(app: ^App) {
	for e in platform.poll_events(app.anchor, false) {
		if e.kind != .Hotkey { continue }
		if source, ok := hotkey_source(e.hotkey); ok { app_trigger(app, source) }
	}
}

@(private = "file")
app_tray_open :: proc(app: ^App) {
	app.tray = platform.tray_create(app.anchor, nil, "cliche")
	if app.tray == nil { return }   // (no notification area: the commands still work)
	icon := tray_icon_rgba(TRAY_ICON_SIZE, context.temp_allocator)
	platform.tray_set_icon_rgba(app.tray, icon, {TRAY_ICON_SIZE, TRAY_ICON_SIZE})
	platform.tray_set_menu(app.tray, {
		{id = int(Tray_Item.Region), text = "Capture a region", default = true},
		{id = int(Tray_Item.Screen), text = "Capture the screen"},
		{id = int(Tray_Item.Window), text = "Capture the window in front"},
		{id = int(Tray_Item.Qr), text = "Read a QR code"},
		{kind = .Separator},
		{id = int(Tray_Item.Settings), text = "Settings"},
		{id = int(Tray_Item.Quit), text = "Quit cliche"},
	})
}

@(private = "file")
app_tray :: proc(app: ^App) {
	if app.tray == nil { return }
	for e in platform.tray_poll(app.tray) {
		#partial switch e.kind {
		case .Click: app_trigger(app, .Region)
		case .Menu_Item:
			switch Tray_Item(e.item) {
			case .Region:   app_trigger(app, .Region)
			case .Screen:   app_trigger(app, .Screen)
			case .Window:   app_trigger(app, .Window)
			case .Qr:       app_trigger(app, .Region, .Qr)
			case .Settings: settings_window_show(app)
			case .Quit:     app.quit = true
			case .None:
			}
		}
	}
}

// A preference was set or reset: the file written on the worker, the settings read again and applied.
app_prefs_changed :: proc(app: ^App) {
	text := config.serialize_user(&app.prefs)
	worker_send(&app.worker, Job_Write{path = strings.clone(prefs_file()), text = text})
	settings_free(&app.settings)
	app.settings = prefs_read(&app.prefs)
	app_hotkeys(app)
}
