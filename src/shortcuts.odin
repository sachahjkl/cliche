package cliche

// Global shortcuts (gt:shortcuts): one per kind of capture, wherever the keyboard is. On Linux the desktop portal binds
// them (the system may ask the user first, and may give other keys than the ones asked: the settings say which); on
// Windows RegisterHotKey. Where the system gives none, the compositor binds keys to cliche's commands (`cliche --region`),
// which reach the running cliche as messages (commands.odin): the settings' Shortcuts page lists them.

import "core:fmt"
import "core:strings"
import "gt:platform"
import shortcuts "gt:shortcuts"
import "gt:ui"

Shortcut_Action :: enum u8 { Region, Screen, Window, Qr, Ocr, Record, Record_Gif }

SHORTCUT_IDS := [Shortcut_Action]string{.Region = "region", .Screen = "screen", .Window = "window", .Qr = "qr", .Ocr = "ocr", .Record = "record", .Record_Gif = "record_gif"}

SHORTCUT_PREFS := [Shortcut_Action]string{
	.Region = "shortcut.region", .Screen = "shortcut.screen", .Window = "shortcut.window", .Qr = "shortcut.qr", .Ocr = "shortcut.ocr", .Record = "shortcut.record", .Record_Gif = "shortcut.record_gif",
}

// What each one does, as the system's list of shortcuts shows it.
SHORTCUT_TEXT := [Shortcut_Action]string{
	.Region = "Capture a region",
	.Screen = "Capture the screen under the pointer",
	.Window = "Capture the window in front",
	.Qr     = "Read a QR code in a region",
	.Ocr    = "Read the text in a region",
	.Record = "Record a region as a video (again: stop)",
	.Record_Gif = "Record a region as a GIF (again: stop)",
}

// The command that does the same, for a compositor's own bindings.
SHORTCUT_COMMANDS := [Shortcut_Action]string{
	.Region = "cliche --region", .Screen = "cliche --screen", .Window = "cliche --window", .Qr = "cliche --qr", .Ocr = "cliche --ocr", .Record = "cliche --record", .Record_Gif = "cliche --record-gif",
}

// The preferences recorded as key combinations in the settings.
SHORTCUT_PREF_NAMES := [?]string{"shortcut.region", "shortcut.screen", "shortcut.window", "shortcut.qr", "shortcut.ocr", "shortcut.record", "shortcut.record_gif"}

// Starts the service with the keys of the preferences.
app_shortcuts_start :: proc(app: ^App) {
	app.shortcuts = shortcuts.start({app_id = APP_NAME, window = app.anchor, wake = app_wake, user = app})
	app_shortcuts_bind(app)
}

app_shortcuts_stop :: proc(app: ^App) {
	shortcuts.stop(app.shortcuts)
	app.shortcuts = nil
}

// The whole set, again (after a change of keys).
app_shortcuts_bind :: proc(app: ^App) {
	list: [len(Shortcut_Action)]shortcuts.Shortcut
	for a in Shortcut_Action {
		hk, _ := platform.hotkey_parse(app.settings.shortcuts[a])   // ("": none asked)
		list[a] = {id = SHORTCUT_IDS[a], description = SHORTCUT_TEXT[a], trigger = hk}
	}
	for &k, a in app.shortcuts_bound {
		delete(k)
		k = strings.clone(app.settings.shortcuts[a])
	}
	shortcuts.bind(app.shortcuts, list[:])
}

// The keys pressed since the last turn of the loop, run.
app_shortcuts_take :: proc(app: ^App) {
	for id in shortcuts.take(app.shortcuts) {
		for a_id, a in SHORTCUT_IDS {
			if a_id == id { app_shortcut_run(app, a) }
		}
	}
}

app_shortcut_run :: proc(app: ^App, a: Shortcut_Action) {
	switch a {
	case .Region: app_trigger(app, .Region)
	case .Screen: app_trigger(app, .Screen)
	case .Window: app_trigger(app, .Window)
	case .Qr:     app_trigger(app, .Region, .Qr)
	case .Ocr:    app_trigger(app, .Region, .Text)
	case .Record: app_record_trigger(app, .Mp4)
	case .Record_Gif: app_record_trigger(app, .Gif)
	}
}

// After the preferences changed: bound again only when a shortcut's keys did.
app_shortcuts_follow_prefs :: proc(app: ^App) {
	changed := false
	for a in Shortcut_Action { if app.settings.shortcuts[a] != app.shortcuts_bound[a] { changed = true } }
	if changed { app_shortcuts_bind(app) }
}

// While a field of the settings records keys, the shortcuts let them go (Windows would take the very keys being
// recorded). Called in the settings' build.
app_shortcuts_recording :: proc(app: ^App) {
	shortcuts.hold(app.shortcuts, ui.hotkey_recording())
}

@(private = "file")
action_of_pref :: proc(name: string) -> (a: Shortcut_Action, ok: bool) {
	for pref, action in SHORTCUT_PREFS { if pref == name { return action, true } }
	return
}

// What the settings say under a shortcut's line, plainly: the keys it works with.
shortcut_status :: proc(app: ^App, name: string) -> string {
	a, ok := action_of_pref(name)
	if !ok { return "" }
	st := shortcuts.status(app.shortcuts, SHORTCUT_IDS[a])
	asked := app.settings.shortcuts[a]
	#partial switch st.state {
	case .Waiting: return asked == "" ? "" : "Waiting for the system's answer…"
	case .Bound:
		if asked == "" || shortcut_same(asked, st.trigger) { return fmt.tprintf("Works in every program: %s.", st.trigger) }
		return fmt.tprintf("The system gave other keys: %s. Change them in its shortcut settings.", st.trigger)
	case .No_Keys:
		if asked == "" { return "No keys: the command works from a compositor binding." }
		return "The system gave no keys yet: choose them in its shortcut settings."
	}
	return ""
}

// What went wrong with a shortcut (red, under its line).
shortcut_problem :: proc(app: ^App, name: string) -> string {
	a, ok := action_of_pref(name)
	if !ok { return "" }
	asked := app.settings.shortcuts[a]
	if asked != "" {
		if _, parsed := platform.hotkey_parse(asked); !parsed { return fmt.tprintf("%q is not a shortcut: click the field and press the keys.", asked) }
	}
	st := shortcuts.status(app.shortcuts, SHORTCUT_IDS[a])
	#partial switch st.state {
	case .Taken:       return fmt.tprintf("Another program holds %s: choose other keys.", st.trigger)
	case .Refused:     return "The system refused this shortcut."
	case .Unavailable: return asked == "" ? "" : "This desktop gives programs no shortcuts of their own: bind the command below in its settings."
	}
	return ""
}

// The same keys, whatever the words ("Ctrl+Shift+4" and "CTRL+SHIFT+4", the portal's "Shift+Print").
@(private = "file")
shortcut_same :: proc(asked, given: string) -> bool {
	a, ok_a := platform.hotkey_parse(asked)
	g, ok_g := platform.hotkey_parse(given)
	if ok_a && ok_g { return a == g }
	return strings.equal_fold(asked, given)
}
