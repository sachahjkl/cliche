package cliche

// Global shortcuts (gt:shortcuts): one per kind of capture, wherever the keyboard is. On Linux the desktop portal binds
// them (the system may ask the user first, and may give other keys than the ones asked: the settings say which); on
// Windows RegisterHotKey. Where the system gives none, the compositor binds keys to cliche's commands (`cliche --region`),
// which reach the running cliche as messages (commands.odin): the settings' Shortcuts page lists them.
//
// The settings' lines of the shortcuts (the keys recorded, what the system said, what went wrong) are gt:prefs_page's:
// it is given the service and SHORTCUT_PAGE_PREFS.

import "core:strings"
import i18n "gt:i18n"
import "gt:platform"
import prefs_page "gt:prefs_page"
import shortcuts "gt:shortcuts"
import "gt:ui"

// In the order of the settings' page and of the tray's menu: the screen, the region, the two recordings, then the rest.
Shortcut_Action :: enum u8 { Screen, Region, Record, Record_Gif, Window, Ocr, Qr }

SHORTCUT_IDS := [Shortcut_Action]string{.Screen = "screen", .Region = "region", .Record = "record", .Record_Gif = "record_gif", .Window = "window", .Ocr = "ocr", .Qr = "qr"}

SHORTCUT_PREFS := [Shortcut_Action]string{
	.Screen = "shortcut.screen", .Region = "shortcut.region", .Record = "shortcut.record", .Record_Gif = "shortcut.record_gif",
	.Window = "shortcut.window", .Ocr = "shortcut.ocr", .Qr = "shortcut.qr",
}

// The settings' page: each preference with its shortcut in the service.
SHORTCUT_PAGE_PREFS := [Shortcut_Action]prefs_page.Shortcut_Pref{
	.Screen     = {pref = "shortcut.screen", id = "screen"},
	.Region     = {pref = "shortcut.region", id = "region"},
	.Record     = {pref = "shortcut.record", id = "record"},
	.Record_Gif = {pref = "shortcut.record_gif", id = "record_gif"},
	.Window     = {pref = "shortcut.window", id = "window"},
	.Ocr        = {pref = "shortcut.ocr", id = "ocr"},
	.Qr         = {pref = "shortcut.qr", id = "qr"},
}

// What each one does, as the system's list of shortcuts shows it.
SHORTCUT_TEXT := [Shortcut_Action]string{
	.Screen     = i18n.later("Capture the screen under the pointer"),
	.Region     = i18n.later("Capture a region"),
	.Record     = i18n.later("Record a region as a video (again: start, then stop)"),
	.Record_Gif = i18n.later("Record a region as a GIF (again: start, then stop)"),
	.Window     = i18n.later("Capture the window in front"),
	.Ocr        = i18n.later("Read the text in a region"),
	.Qr         = i18n.later("Read a QR code in a region"),
}

// The command that does the same, for a compositor's own bindings.
SHORTCUT_COMMANDS := [Shortcut_Action]string{
	.Screen = "cliche --screen", .Region = "cliche --region", .Record = "cliche --record", .Record_Gif = "cliche --record-gif",
	.Window = "cliche --window", .Ocr = "cliche --ocr", .Qr = "cliche --qr",
}

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
		list[a] = {id = SHORTCUT_IDS[a], description = i18n.tr(SHORTCUT_TEXT[a]), trigger = hk}
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
	case .Screen: app_trigger(app, .Screen)
	case .Region: app_trigger(app, .Region)
	case .Record: app_record_trigger(app, .Mp4)
	case .Record_Gif: app_record_trigger(app, .Gif)
	case .Window: app_trigger(app, .Window)
	case .Ocr:    app_trigger(app, .Ocr)
	case .Qr:     app_trigger(app, .Qr)
	}
}

// After the preferences changed: bound again only when a shortcut's keys did.
app_shortcuts_follow_prefs :: proc(app: ^App) {
	changed := false
	for a in Shortcut_Action { if app.settings.shortcuts[a] != app.shortcuts_bound[a] { changed = true } }
	if changed { app_shortcuts_bind(app) }
}

// The keys that run `a` now, in hotkey_text's words ("Ctrl+Print"): the system's when it bound them (they may differ
// from the ones asked), else the ones asked in the settings, else "". Temp allocator.
shortcut_keys :: proc(app: ^App, a: Shortcut_Action) -> string {
	if app.shortcuts != nil {
		st := shortcuts.status(app.shortcuts, SHORTCUT_IDS[a])
		if st.state == .Bound && st.trigger != "" {
			// (the portal words them its own way, "CTRL+SHIFT+a": the same words as the settings' everywhere)
			if hk, ok := platform.hotkey_parse(st.trigger); ok { return hotkey_shown(hk) }
			return st.trigger
		}
	}
	if hk, ok := platform.hotkey_parse(app.settings.shortcuts[a]); ok { return hotkey_shown(hk) }
	return ""
}

// A hotkey as the keyboards of the language print it ("Maj+Impr. écran" in French), for a text that is read, not typed:
// the settings' fields keep hotkey_text's English words, which hotkey_parse reads back. (The toolkit's ui.key_name names
// no Print key, nor a hotkey: this belongs in the toolkit's platform.hotkey_text once it has the language's words.)
hotkey_shown :: proc(hk: platform.Hotkey, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if .Ctrl in hk.mods  { strings.write_string(&b, i18n.tr("key", "Ctrl")); strings.write_byte(&b, '+') }
	if .Shift in hk.mods { strings.write_string(&b, i18n.tr("key", "Shift")); strings.write_byte(&b, '+') }
	if .Alt in hk.mods   { strings.write_string(&b, i18n.tr("key", "Alt")); strings.write_byte(&b, '+') }
	if hk.super          { strings.write_string(&b, "Win+") }
	switch {
	case hk.key == .None && hk.char != 0: strings.write_rune(&b, hk.char)
	case hk.key == .Print:                strings.write_string(&b, i18n.tr("key", "Print"))
	case ui.key_name(hk.key) != "":       strings.write_string(&b, ui.key_name(hk.key))
	// (a key the toolkit does not name: the hotkey's own word for it)
	case:                                 strings.write_string(&b, platform.hotkey_text({key = hk.key}))
	}
	return strings.to_string(b)
}
