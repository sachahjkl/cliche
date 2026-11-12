package cliche

// The running cliche: one process for the session, in the notification area. What it holds at rest is small: a window
// that is never shown (the anchor: the tray icon, the notifications, the hotkeys and the clipboard are a window's), the
// worker's thread with the capture session, and the thread that hears other starts. The renderer is made at the first
// window that needs one (the overlay of a region, the main window), and that window is then hidden, not closed, so that
// it comes back at once.
//
// The windows: the region's overlay (overlay.odin), the main window with the history, the workflows and the settings
// (history_view.odin, workflow_view.odin, settings_view.odin), the editor (editor.odin), and the record overlay over the
// other programs while a recording is ready or runs (record_overlay.odin).
//
// A capture's picture goes to a run of the workflow its trigger runs (workflow_app.odin): the flow of the capture ends
// there, and the run goes on beside the next captures.
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
import shortcuts "gt:shortcuts"
import "gt:platform"
import "gt:render"

// The tray menu's items. The first seven are Shortcut_Action's, in its order.
Tray_Item :: enum { None, Screen, Region, Record, Record_Gif, Window, Ocr, Qr, Edit, Record_Start, Record_Stop, Record_Cancel, History, Workflows, Settings, Quit }

// A command another start handed over (token owned).
Inbox_Item :: struct { verb: Verb, token: string }

// The windows other threads wake.
Window_Slot :: enum u8 { Anchor, Overlay, History, Editor, Record_Overlay }

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
	history_window: History_Window,                        // history_view.odin: the main window, with the settings
	editor:     Editor,                                    // editor.odin
	record_overlay: Record_Overlay,                        // record_overlay.odin
	prewarmed:  bool,                                      // the editor was opened ahead (app_prewarm)
	notice_entry: u64,                                     // the history's entry of the last notification (a click shows it)

	flow:       Flow,                                      // flow.odin
	desktop:    Result_Desktop,                            // the region's desktop, from Selecting to its cut (owned)
	has_desktop: bool,
	capture_trigger: Trigger,                              // what started this capture: its workflow runs on its picture
	capture_record: bool,                                  // this capture is a recording's region (record_app.odin)
	workflows:  Workflows,                                 // workflow.odin, workflow_store.odin
	workflows_loaded: bool,
	workflows_problem: string,                             // why the file was not used (owned; "" none)
	workflows_save_due: bool,                              // a change is not written yet
	runs:       [dynamic]^Run,                             // the runs in flight (workflow_app.odin)
	run_next_id: u64,
	annotate_queue: [dynamic]Annotate_Ask,                 // Annotate nodes waiting for the editor
	editor_for: Annotate_Ask,                              // the run and node the editor's picture is for (run 0: none)
	record:     Record_Flow,                               // the recording's state (record.odin)
	recorder:   Recorder,                                  // its thread, while one runs
	record_region: Rect,                                   // its region, logical
	record_output: Rect,                                   // the output that holds it, logical (the record overlay covers it)
	uploaders:  Result_Uploaders,                          // the uploaders found, for the settings (owned)
	token:      string,                                    // the activation token of the next window shown (owned)
	backend:    capture.Backend,                           // the session's, once open
	notice:     platform.Notification_Id,                  // the last notification: the next one replaces it
	shortcuts:  ^shortcuts.Service,                        // shortcuts.odin
	shortcuts_bound: [Shortcut_Action]string,              // the keys the service was given last (owned)
	tray_keys:  [Shortcut_Action]string,                   // the keys the tray's menu shows (owned): built again when they change
	tray_menu:  Tray_Menu,                                 // the menu shown
	default_folder: string,                                // where screenshots go when save.folder is empty (the worker's, owned)
	integrated: [2]bool,                                   // general.menu and general.autostart as applied last
	quit:       bool,
}

app_run :: proc(prefs: ^config.Prefs, owner: instance.Owner, first: Command) -> int {
	app := new(App)
	defer free(app)
	app.prefs = prefs^
	prefs^ = {}
	app.settings = prefs_read(&app.prefs)
	app.flow = Flow_Idle{}
	app.record = Record_Idle{}

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
	history_start(app)
	workflows_start(app)
	app.server = instance.serve_start(owner, app_message, app)
	app_tray_open(app)
	app_shortcuts_start(app)
	app_integrate(app, force = true)
	app_command(app, first.verb, first.token)

	for !app.quit {
		app_prewarm(app)
		app_wait(app)
		app_anchor_events(app)
		app_inbox(app)
		app_tray(app)
		app_results(app)
		app_shortcuts_take(app)
		app_record_messages(app)
		app_tray_follow(app)
		app_frames(app)
	}

	instance.serve_stop(app.server)
	app_shortcuts_stop(app)
	recorder_join(&app.recorder)   // (a recording running is stopped, its file closed)
	workflows_save(app)   // (a change still waiting for the end of its gesture)
	worker_stop(&app.worker)   // (before the desktop goes: a cut may be reading it)
	workflows_stop(app)   // (after the worker: its jobs held the runs' pictures)
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
	for k in app.shortcuts_bound { delete(k) }
	for k in app.tray_keys { delete(k) }
	uploaders_result_free(&app.uploaders)
	delete(app.default_folder)
	settings_free(&app.settings)
	config.prefs_destroy(&app.prefs)
}

// The editor opened hidden before its first picture, when a screenshot's workflow opens it (Annotate): its window, its
// surface and the graphics driver are then ready, and a shortcut shows it at once. The driver is loaded on a thread
// first (its done wakes this loop): the interface's thread never waits for it.
@(private = "file")
app_prewarm :: proc(app: ^App) {
	if app.editor.opened || app.prewarmed || !workflows_want_editor(app) { return }
	if app.shared.main == nil {
		#partial switch render.device_preload_state() {
		case .Not_Started: render.preload_device(done = app_wake, user = app); return
		case .Creating:    return
		}
	}
	app.prewarmed = true   // (once: a window that cannot open is not asked again at every turn)
	editor_open(app, headless = false)
}

// The shown windows' frames, else the anchor: what ends the wait is a wake of any window (app_wake), input, the tray.
@(private = "file")
app_wait :: proc(app: ^App) {
	shown := make([dynamic]^host.Host, 0, 4, context.temp_allocator)
	if app.overlay.visible { append(&shown, &app.overlay.host) }
	if app.history_window.visible { append(&shown, &app.history_window.host) }
	if app.editor.visible { append(&shown, &app.editor.host) }
	if app.record_overlay.visible { append(&shown, &app.record_overlay.host) }
	if len(shown) > 0 { host.hosts_wait(shown[:]) } else { platform.wait_event(app.anchor, 0) }
}

// A frame of each shown window, then what it decided. A close the system asked for is read after the frame
// (app_close_asked): each of these windows is hidden or given up, never closed by the system.
@(private = "file")
app_frames :: proc(app: ^App) {
	if app.overlay.visible {
		overlay_prepare(app)
		host.host_frame(&app.overlay.host)
		if app_close_asked(&app.overlay.host) { app.overlay.decision = .Cancel }
		overlay_after_frame(app)
	}
	if app.history_window.visible {
		host.host_frame(&app.history_window.host)
		if app_close_asked(&app.history_window.host) { app.history_window.hide_due = true }
		history_after_frame(app)
	}
	if app.editor.visible {
		host.host_frame(&app.editor.host)
		timing_mark("editor frame")
		if app_close_asked(&app.editor.host) {
			editor_close_asked(app)
			app.editor.host.settle = max(app.editor.host.settle, 2)   // (its question, when it asks one, is drawn)
		}
		editor_after_frame(app)
	}
	if app.record_overlay.visible {
		host.host_frame(&app.record_overlay.host)
		if app_close_asked(&app.record_overlay.host) { app.record_overlay.decision = .Cancel }
		record_overlay_after_frame(app)
	}
}

// The system asked to close `h`'s window (its title bar's button, Alt+F4): the ask is taken back, the caller hides it.
// gt:host's frame ends at once on a window marked closed, before its input hook sees the .Close event: a window whose
// hook alone cancels the close would stay shown, and every later frame of it would end there too.
@(private = "file")
app_close_asked :: proc(h: ^host.Host) -> bool {
	if h.win == nil || !platform.is_closed(h.win) { return false }
	platform.cancel_close(h.win)
	return true
}

// The windows with a renderer close in the order the host asks: the renderer's own window last.
@(private = "file")
app_windows_close :: proc(app: ^App) {
	overlay_destroy(app)
	// (textures go while the renderer is there: before any host closes)
	history_window_free(app)
	editor_destroy(app)
	hosts := [4]^host.Host{&app.overlay.host, &app.history_window.host, &app.editor.host, &app.record_overlay.host}
	opened := [4]bool{app.overlay.opened, app.history_window.opened, app.editor.opened, app.record_overlay.opened}
	for h, i in hosts { if opened[i] && app.shared.main != h { host.host_close(h) } }
	for h, i in hosts { if opened[i] && app.shared.main == h { host.host_close(h) } }
	editor_free(app)
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
	case .Qr:       app_trigger(app, .Qr)
	case .Ocr:      app_trigger(app, .Ocr)
	case .Record:     app_record_trigger(app, .Mp4)
	case .Record_Gif: app_record_trigger(app, .Gif)
	case .Edit:     app_trigger(app, .Edit)
	case .Workflows: workflows_show(app)
	case .History:  history_window_show(app)
	case .Settings: settings_show(app)
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

// A capture for `t`'s workflow starts. False: one is already being taken (one at a time).
app_trigger :: proc(app: ^App, t: Trigger) -> bool {
	return app_capture_start(app, TRIGGER_SOURCE[t], t, record = false)
}

// A capture of `source` starts: for the workflow of `t`, or for a recording's region (`record`).
app_capture_start :: proc(app: ^App, source: Source, t: Trigger, record: bool) -> bool {
	if !app_step(app, Flow_Trigger{source}) { return false }
	timing_start(SOURCE_NAMES[source])
	app.capture_trigger, app.capture_record = t, record
	// (the renderer's device made while the desktop is read: the overlay's first show does not wait for the driver)
	if source == .Region && app.shared.main == nil && render.device_preload_state() == .Not_Started { render.preload_device() }
	// (a region's picture is frozen while it is chosen: no delay; a screen or a window waits, for a menu to open)
	delay := source == .Region ? 0 : app.settings.delay_s * 1000
	worker_send(&app.worker, Job_Grab{source, delay})
	return true
}

// The worker's results, in order.
@(private = "file")
app_results :: proc(app: ^App) {
	for r in worker_take(&app.worker) {
		switch v in r {
		case Result_Opened:
			app.backend = v.backend
			delete(app.default_folder)
			app.default_folder = v.default_folder
			if v.error != .None { fmt.eprintfln("cliche: no capture here: %s", FLOW_ERROR_TEXT[flow_error_of(v.error)]) }
		case Result_Folder:
			if v.node != 0 {
				workflow_folder_chosen(app, v.workflow, v.node, v.path)
			} else if v.path != "" && config.set_from_string(&app.prefs, "save.folder", v.path, .User) == .None {
				app_prefs_changed(app)
			}
			delete(v.path)
		case Result_Node:
			workflow_node_result(app, v)
		case Result_Workflows:
			workflows_loaded(app, v)
		case Result_Picture:
			workflow_preview_picture(app, v)
		case Result_History:
			history_result(app, v)
		case Result_Uploaders:
			app_uploaders(app, v)
		case Result_Integrated:
			if v.problem != "" { fmt.eprintfln("cliche: %s", v.problem) }
			delete(v.problem)
		case Result_Desktop:
			app_desktop(app, v)
		case Result_Shot:
			app_shot(app, v)
		case Result_Saved:
			app_saved(app, v)
		case Result_Written:
			if !v.ok { fmt.eprintfln("cliche: %s cannot be written", v.path) }
			delete(v.path)
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
		if app.capture_record { app_record_abandoned(app, failed = true); app_step(app, Flow_Reset{}); return }
		app_outcome(app)
		return
	}
	app.desktop, app.has_desktop = d, true
	app_step(app, Flow_Captured{})
	if !overlay_show(app) {
		app_desktop_drop(app)
		app_step(app, Flow_Capture_Failed{.Failed})
		if app.capture_record { app_record_abandoned(app, failed = true); app_step(app, Flow_Reset{}); return }
		app_outcome(app)
	}
}

app_desktop_drop :: proc(app: ^App) {
	if app.has_desktop { desktop_free(&app.desktop) }
	app.has_desktop = false
}

// What the overlay decided, after its frame.
app_region_confirmed :: proc(app: ^App, r: Rect) {
	if app.capture_record {
		overlay_hide(app)
		app_record_chosen(app, r)
		return
	}
	if !app_step(app, Flow_Confirmed{}) { return }
	overlay_hide(app)
	// (the desktop stays until the cut comes back: the worker reads it)
	worker_send(&app.worker, Job_Crop{app.desktop.frame, r})
}

app_region_cancelled :: proc(app: ^App) {
	app_step(app, Flow_Cancelled{})
	overlay_hide(app)
	app_desktop_drop(app)
	if app.capture_record { app_record_abandoned(app, failed = false) }
}

@(private = "file")
app_shot :: proc(app: ^App, r: Result_Shot) {
	timing_mark("picture from the worker")
	r := r
	#partial switch s in app.flow {
	case Flow_Capturing:
		if r.error != .None {
			app_step(app, Flow_Capture_Failed{r.error})
			app_outcome(app)
			return
		}
		app_step(app, Flow_Captured{})
		app_chain(app, r.shot)
	case Flow_Encoding:
		if s.source == .Region { app_desktop_drop(app) }
		if r.error != .None {
			shot_free(&r.shot)
			app_step(app, Flow_Save_Failed{r.error})
			app_outcome(app)
			return
		}
		app_chain(app, r.shot)
	case:
		shot_free(&r.shot)
	}
}

// The picture of a capture goes to a run of its trigger's workflow (workflow_app.odin), which owns it from now on: the
// capture is over (Flow_Handed), and another may start while the run goes on. A recording's region comes from the overlay:
// no picture comes here.
@(private = "file")
app_chain :: proc(app: ^App, shot: Shot) {
	if app.capture_record {
		shot := shot
		shot_free(&shot)
		return
	}
	if workflow_capture(app, app.capture_trigger, shot) {
		app_step(app, Flow_Handed{})
		return
	}
	app_step(app, Flow_Save_Failed{.No_Workflow})
	app_outcome(app)
}

// What the worker said of the editor's Ctrl+S: told in the editor.
@(private = "file")
app_saved :: proc(app: ^App, r: Result_Saved) {
	defer delete(r.path)
	editor_saved(app, r.path, r.error)
}

// A capture that failed: told to the user, then Idle. (A capture that worked is told by its workflow's run.)
@(private = "file")
app_outcome :: proc(app: ^App) {
	if s, failed := app.flow.(Flow_Failed); failed {
		title := "No screenshot"
		#partial switch app.capture_trigger {
		case .Qr:  title = "No QR code"
		case .Ocr: title = "No text"
		}
		body := FLOW_ERROR_TEXT[s.error]
		fmt.eprintfln("cliche: %s", body)
		if id, ok := platform.notify(app.anchor, {title = title, body = body, silent = true, replace = app.notice}); ok { app.notice = id }
	}
	app_step(app, Flow_Reset{})
}

// The anchor's events: the shortcuts' presses (Windows: a hotkey is a window's event).
@(private = "file")
app_anchor_events :: proc(app: ^App) {
	for e in platform.poll_events(app.anchor, false) {
		if shortcuts.feed(app.shortcuts, e) { continue }
		if e.kind == .Notification_Click {
			// (the notification's activation token lets the history's window come to the front on Wayland)
			delete(app.token)
			app.token = strings.clone(platform.notify_activation_token(app.anchor))
			history_window_show(app, app.notice_entry)
		}
	}
}

@(private = "file")
app_tray_open :: proc(app: ^App) {
	app.tray = platform.tray_create(app.anchor, nil, "cliche")
	if app.tray == nil { return }   // (no notification area: the commands still work)
	app_tray_icon(app, recording = false)
	app_tray_menu(app)
}

// The tray's icon: the corners of a selection, with a red dot while the recorder runs.
app_tray_icon :: proc(app: ^App, recording: bool) {
	if app.tray == nil { return }
	icon := recording ? tray_icon_recording_rgba(TRAY_ICON_SIZE, context.temp_allocator) : tray_icon_rgba(TRAY_ICON_SIZE, context.temp_allocator)
	platform.tray_set_icon_rgba(app.tray, icon, {TRAY_ICON_SIZE, TRAY_ICON_SIZE})
}

// The menus of the tray: at rest, while a recording is ready, while it runs.
Tray_Menu :: enum u8 { Rest, Ready, Recording }

@(private = "file")
TRAY_SHORTCUT_TEXT := [Shortcut_Action]string{
	.Screen = "Capture the screen", .Region = "Capture a region", .Record = "Record a video", .Record_Gif = "Record a GIF",
	.Window = "Capture the window in front", .Ocr = "Read the text", .Qr = "Read a QR code",
}

// The tray's menu for the recording's state, each command with the keys that run it (tray_keys).
app_tray_menu :: proc(app: ^App) {
	if app.tray == nil { return }
	switch {
	case record_running(app.record): app.tray_menu = .Recording
	case record_ready(app.record):   app.tray_menu = .Ready
	case:                            app.tray_menu = .Rest
	}
	items := make([dynamic]platform.Tray_Menu_Item, 0, 16, context.temp_allocator)
	switch app.tray_menu {
	case .Ready:
		keys := app.tray_keys[record_format(app.record) == .Gif ? .Record_Gif : .Record]
		append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Record_Start), text = "Start recording", default = true, shortcut = keys})
		append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Record_Cancel), text = "Cancel"})
	case .Recording:
		keys := app.tray_keys[record_format(app.record) == .Gif ? .Record_Gif : .Record]
		append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Record_Stop), text = "Stop recording", default = true, shortcut = keys})
		append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Record_Cancel), text = "Cancel recording"})
	case .Rest:
		default_item := tray_item_of_click(app.settings.tray_click)
		for a in Shortcut_Action {
			item := Tray_Item(int(Tray_Item.Screen) + int(a))
			append(&items, platform.Tray_Menu_Item{id = int(item), text = TRAY_SHORTCUT_TEXT[a], default = item == default_item, shortcut = app.tray_keys[a]})
		}
		append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Edit), text = "Capture a region and edit"})
	}
	append(&items, platform.Tray_Menu_Item{kind = .Separator})
	append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.History), text = "History", default = app.tray_menu == .Rest && app.settings.tray_click == .History})
	append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Workflows), text = "Workflows"})
	append(&items, platform.Tray_Menu_Item{kind = .Separator})
	append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Settings), text = "Settings", default = app.tray_menu == .Rest && app.settings.tray_click == .Settings})
	append(&items, platform.Tray_Menu_Item{id = int(Tray_Item.Quit), text = "Quit cliche"})
	platform.tray_set_menu(app.tray, items[:])
}

// The tray item a click on the icon runs (general.tray_click): the menu marks it as the default.
@(private = "file")
tray_item_of_click :: proc(c: Tray_Click) -> Tray_Item {
	switch c {
	case .Region:   return .Region
	case .Screen:   return .Screen
	case .Window:   return .Window
	case .Qr:       return .Qr
	case .Ocr:      return .Ocr
	case .Record:   return .Record
	case .History:  return .History
	case .Settings: return .Settings
	}
	return .None
}

// Once a turn of the loop: the menu built again when the keys that work changed (the settings, or the system's answer:
// the shortcuts' service wakes the loop when it comes), or the recording's state did. A few strings compared, not a frame's
// work.
@(private = "file")
app_tray_follow :: proc(app: ^App) {
	if app.tray == nil { return }
	changed := false
	for a in Shortcut_Action {
		keys := shortcut_keys(app, a)
		if keys == app.tray_keys[a] { continue }
		delete(app.tray_keys[a])
		app.tray_keys[a] = strings.clone(keys)
		changed = true
	}
	menu := Tray_Menu.Rest
	if record_running(app.record) { menu = .Recording } else if record_ready(app.record) { menu = .Ready }
	if changed || menu != app.tray_menu { app_tray_menu(app) }
}

@(private = "file")
app_tray :: proc(app: ^App) {
	if app.tray == nil { return }
	for e in platform.tray_poll(app.tray) {
		#partial switch e.kind {
		case .Click:
			// (while a recording is ready a click starts it; while it runs a click stops it)
			if record_ready(app.record) { app_record_start(app); continue }
			if record_running(app.record) { app_record_stop(app); continue }
			switch app.settings.tray_click {
			case .Region:   app_trigger(app, .Region)
			case .Screen:   app_trigger(app, .Screen)
			case .Window:   app_trigger(app, .Window)
			case .Qr:       app_trigger(app, .Qr)
			case .Ocr:      app_trigger(app, .Ocr)
			case .Record:   app_record_trigger(app, .Mp4)
			case .History:  history_window_show(app)
			case .Settings: settings_show(app)
			}
		case .Menu_Item:
			switch Tray_Item(e.item) {
			case .Screen, .Region, .Record, .Record_Gif, .Window, .Ocr, .Qr:
				app_shortcut_run(app, Shortcut_Action(e.item - int(Tray_Item.Screen)))
			case .Edit:          app_trigger(app, .Edit)
			case .Workflows:     workflows_show(app)
			case .Record_Start:  app_record_start(app)
			case .Record_Stop:   app_record_stop(app)
			case .Record_Cancel: app_record_cancel(app)
			case .History:       history_window_show(app)
			case .Settings:      settings_show(app)
			case .Quit:          app.quit = true
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
	app_shortcuts_follow_prefs(app)
	app_integrate(app, force = false)
	history_prefs_changed(app)
}

// cliche's launcher and its start with the session as the preferences say: at the start (the files may have gone),
// then when one of the two changes.
app_integrate :: proc(app: ^App, force: bool) {
	want := [2]bool{app.settings.menu, app.settings.autostart}
	if !force && want == app.integrated { return }
	app.integrated = want
	worker_send(&app.worker, Job_Integrate{menu = want[0], autostart = want[1]})
}

// The uploaders found (the settings' list); one just imported becomes the one used.
@(private = "file")
app_uploaders :: proc(app: ^App, r: Result_Uploaders) {
	uploaders_result_free(&app.uploaders)
	app.uploaders = r
	if r.imported != "" && config.set_from_string(&app.prefs, "upload.uploader", r.imported, .User) == .None { app_prefs_changed(app) }
	if r.import_problem != "" { fmt.eprintfln("cliche: %s", r.import_problem) }
}
