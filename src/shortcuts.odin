package cliche

// Global shortcuts (gt:shortcuts): one per kind of capture, and one per workflow that has keys of its own (its Capture
// node's "shortcut": workflow.odin's Capture_Options), wherever the keyboard is. On Linux the desktop portal binds them
// (the system may ask the user first, and may give other keys than the ones asked: the settings say which); on Windows
// RegisterHotKey. Where the system gives none, the compositor binds keys to cliche's commands (`cliche --region`),
// which reach the running cliche as messages (commands.odin): the settings' Shortcuts page lists them.
//
// The settings' lines of the fixed shortcuts (the keys recorded, what the system said, what went wrong) are
// gt:prefs_page's: it is given the service and SHORTCUT_PAGE_PREFS. A workflow's keys are recorded in its Capture node
// (the Workflows mode); the Shortcuts page lists them under the fixed ones (settings_view.odin).

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import shortcuts "gt:shortcuts"

// In the order of the settings' page and of the tray's menu: the screen, the region, the two recordings, then the rest.
Shortcut_Action :: enum u8 { Screen, Region, Record, Record_Gif, Window, Ocr, Qr, All_Screens, Last_Region, Color }

SHORTCUT_IDS := [Shortcut_Action]string{
	.Screen = "screen", .Region = "region", .Record = "record", .Record_Gif = "record_gif", .Window = "window", .Ocr = "ocr", .Qr = "qr",
	.All_Screens = "all_screens", .Last_Region = "last_region", .Color = "color",
}

SHORTCUT_PREFS := [Shortcut_Action]string{
	.Screen = "shortcut.screen", .Region = "shortcut.region", .Record = "shortcut.record", .Record_Gif = "shortcut.record_gif",
	.Window = "shortcut.window", .Ocr = "shortcut.ocr", .Qr = "shortcut.qr",
	.All_Screens = "shortcut.all_screens", .Last_Region = "shortcut.last_region", .Color = "shortcut.color",
}

// The settings' page: each preference with its shortcut in the service.
SHORTCUT_PAGE_PREFS := [Shortcut_Action]prefs_page.Shortcut_Pref{
	.Screen      = {pref = "shortcut.screen", id = "screen"},
	.Region      = {pref = "shortcut.region", id = "region"},
	.Record      = {pref = "shortcut.record", id = "record"},
	.Record_Gif  = {pref = "shortcut.record_gif", id = "record_gif"},
	.Window      = {pref = "shortcut.window", id = "window"},
	.Ocr         = {pref = "shortcut.ocr", id = "ocr"},
	.Qr          = {pref = "shortcut.qr", id = "qr"},
	.All_Screens = {pref = "shortcut.all_screens", id = "all_screens"},
	.Last_Region = {pref = "shortcut.last_region", id = "last_region"},
	.Color       = {pref = "shortcut.color", id = "color"},
}

// What each one does, as the system's list of shortcuts shows it.
SHORTCUT_TEXT := [Shortcut_Action]string{
	.Screen      = i18n.later("Capture the screen under the pointer"),
	.Region      = i18n.later("Capture a region"),
	.Record      = i18n.later("Record a region as a video (again: start, then stop)"),
	.Record_Gif  = i18n.later("Record a region as a GIF (again: start, then stop)"),
	.Window      = i18n.later("Capture the window in front"),
	.Ocr         = i18n.later("Read the text in a region"),
	.Qr          = i18n.later("Read a QR code in a region"),
	.All_Screens = i18n.later("Capture all the screens"),
	.Last_Region = i18n.later("Capture the last region again"),
	.Color       = i18n.later("Pick a colour on the screen"),
}

// The command that does the same, for a compositor's own bindings.
SHORTCUT_COMMANDS := [Shortcut_Action]string{
	.Screen = "cliche --screen", .Region = "cliche --region", .Record = "cliche --record", .Record_Gif = "cliche --record-gif",
	.Window = "cliche --window", .Ocr = "cliche --ocr", .Qr = "cliche --qr",
	.All_Screens = "cliche --all-screens", .Last_Region = "cliche --last-region", .Color = "cliche --color",
}

// A workflow's keys as the service was given them last (owned).
Bound_Workflow :: struct {
	workflow: u64,
	keys:     string,
	name:     string,
}

// Starts the service with the keys of the preferences and of the workflows.
app_shortcuts_start :: proc(app: ^App) {
	app.shortcuts = shortcuts.start({app_id = APP_NAME, window = app.anchor, wake = app_wake, user = app})
	app_shortcuts_bind(app)
}

app_shortcuts_stop :: proc(app: ^App) {
	shortcuts.stop(app.shortcuts)
	app.shortcuts = nil
	bound_workflows_free(app)
}

@(private = "file")
bound_workflows_free :: proc(app: ^App) {
	for b in app.shortcuts_workflows {
		delete(b.keys)
		delete(b.name)
	}
	delete(app.shortcuts_workflows)
	app.shortcuts_workflows = nil
}

// The whole set, again (after a change of keys): the fixed ones, then each workflow's.
app_shortcuts_bind :: proc(app: ^App) {
	flows := workflows_shortcuts(&app.workflows)
	list := make([dynamic]shortcuts.Shortcut, 0, len(Shortcut_Action) + len(flows), context.temp_allocator)
	for a in Shortcut_Action {
		hk, _ := platform.hotkey_parse(app.settings.shortcuts[a])   // ("": none asked)
		append(&list, shortcuts.Shortcut{id = SHORTCUT_IDS[a], description = i18n.tr(SHORTCUT_TEXT[a]), trigger = hk})
	}
	for &k, a in app.shortcuts_bound {
		delete(k)
		k = strings.clone(app.settings.shortcuts[a])
	}
	bound_workflows_free(app)
	for f in flows {
		hk, _ := platform.hotkey_parse(f.keys)
		append(&list, shortcuts.Shortcut{id = workflow_shortcut_id(f.workflow), description = fmt.tprintf(i18n.tr("Run the workflow \"%s\""), f.name), trigger = hk})
		append(&app.shortcuts_workflows, Bound_Workflow{f.workflow, strings.clone(f.keys), strings.clone(f.name)})
	}
	app.shortcuts_workflows_version = app.workflows.version
	shortcuts.bind(app.shortcuts, list[:])
}

// The keys pressed since the last turn of the loop, run. The workflows' keys are bound again first when they changed.
app_shortcuts_take :: proc(app: ^App) {
	app_shortcuts_follow_workflows(app)
	for id in shortcuts.take(app.shortcuts) {
		if wf, is_workflow := workflow_of_shortcut(id); is_workflow {
			app_workflow_shortcut(app, wf)
			continue
		}
		for a_id, a in SHORTCUT_IDS {
			if a_id == id { app_shortcut_run(app, a) }
		}
	}
}

app_shortcut_run :: proc(app: ^App, a: Shortcut_Action) {
	switch a {
	case .Screen:      app_trigger(app, .Screen)
	case .Region:      app_trigger(app, .Region)
	case .Record:      app_record_trigger(app, .Mp4)
	case .Record_Gif:  app_record_trigger(app, .Gif)
	case .Window:      app_trigger(app, .Window)
	case .Ocr:         app_trigger(app, .Ocr)
	case .Qr:          app_trigger(app, .Qr)
	case .All_Screens: app_trigger(app, .All_Screens)
	case .Last_Region: app_trigger(app, .Last_Region)
	case .Color:       app_color_pick(app)
	}
}

// After the preferences changed: bound again only when a shortcut's keys did.
app_shortcuts_follow_prefs :: proc(app: ^App) {
	changed := false
	for a in Shortcut_Action { if app.settings.shortcuts[a] != app.shortcuts_bound[a] { changed = true } }
	if changed { app_shortcuts_bind(app) }
}

// Once a turn: when the workflows changed (their version), bound again only if a workflow's keys, its name (the
// system's list shows it) or the list of them did. A few strings compared, at a change only.
@(private = "file")
app_shortcuts_follow_workflows :: proc(app: ^App) {
	if app.shortcuts == nil || app.workflows.version == app.shortcuts_workflows_version { return }
	app.shortcuts_workflows_version = app.workflows.version
	flows := workflows_shortcuts(&app.workflows)
	same := len(flows) == len(app.shortcuts_workflows)
	for f, i in flows {
		if !same { break }
		b := app.shortcuts_workflows[i]
		same = b.workflow == f.workflow && b.keys == f.keys && b.name == f.name
	}
	if !same { app_shortcuts_bind(app) }
}

// The keys that run `a` now, as the keyboards of the language print them (platform.key_text: "Ctrl+Impr. écran" in
// French), for a text that is read: the system's when it bound them (they may differ from the ones asked), else the ones
// asked in the settings, else "". Temp allocator.
shortcut_keys :: proc(app: ^App, a: Shortcut_Action) -> string {
	return shortcut_keys_of(app, SHORTCUT_IDS[a], app.settings.shortcuts[a])
}

// The keys of the workflow `id`'s own shortcut now, as shortcut_keys says them ("": none).
workflow_shortcut_keys :: proc(app: ^App, id: u64) -> string {
	o := capture_options(workflows_find(&app.workflows, id))
	return shortcut_keys_of(app, workflow_shortcut_id(id), o.shortcut)
}

@(private = "file")
shortcut_keys_of :: proc(app: ^App, id, asked: string) -> string {
	if app.shortcuts != nil {
		st := shortcuts.status(app.shortcuts, id)
		if st.state == .Bound && st.trigger != "" {
			// (the portal words them its own way, "CTRL+SHIFT+a": the same words as the settings' everywhere)
			if hk, ok := platform.hotkey_parse(st.trigger); ok { return platform.key_text(hk) }
			return platform.key_text(st.trigger)
		}
	}
	if hk, ok := platform.hotkey_parse(asked); ok { return platform.key_text(hk) }
	return ""
}
