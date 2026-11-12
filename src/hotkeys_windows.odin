#+build windows
package cliche

// Windows: one hotkey per source (shortcut.region, shortcut.screen, shortcut.window), registered on the anchor window, and
// registered again when a preference changes. What went wrong shows under the preference's line in the settings.

import "core:fmt"
import "gt:platform"
import "gt:ui"

Hotkeys :: struct {
	held:     [Source]bool,
	problems: [Source]string,   // owned; "": it works, or none is set
	paused:   bool,             // let go while a field of the settings records keys
}

SHORTCUT_PREFS := [Source]string{.Region = "shortcut.region", .Screen = "shortcut.screen", .Window = "shortcut.window"}

// The id of a source's hotkey: its index, from 1.
hotkey_source :: proc(id: int) -> (s: Source, ok: bool) {
	if id < 1 || id > len(Source) { return }
	return Source(id - 1), true
}

app_hotkeys :: proc(app: ^App) {
	hk := &app.hotkeys
	for source in Source {
		id := int(source) + 1
		if hk.held[source] { platform.hotkey_unregister(app.anchor, id) }
		hk.held[source] = false
		delete(hk.problems[source])
		hk.problems[source] = ""
		text := app.settings.shortcuts[source]
		if text == "" { continue }   // (none asked)
		combo, ok := platform.hotkey_parse(text)
		switch {
		case !ok:
			hk.problems[source] = fmt.aprintf("%q is not a shortcut: click the field and press the keys.", text)
		case !platform.hotkey_register(app.anchor, id, combo):
			hk.problems[source] = fmt.aprintf("%s cannot be used: Windows or another program holds it. Choose other keys.", platform.hotkey_text(combo))
		case:
			hk.held[source] = true
		}
		if hk.problems[source] != "" { fmt.eprintfln("cliche: %s: %s", SHORTCUT_PREFS[source], hk.problems[source]) }
	}
	hk.paused = false
}

// While a field of the settings records keys, the hotkeys are let go (Windows would take the very keys being recorded).
// Called in the settings' build.
app_hotkeys_follow :: proc(app: ^App) {
	recording := ui.hotkey_recording()
	if recording && !app.hotkeys.paused {
		for source in Source {
			if app.hotkeys.held[source] { platform.hotkey_unregister(app.anchor, int(source) + 1) }
			app.hotkeys.held[source] = false
		}
		app.hotkeys.paused = true
	} else if !recording && app.hotkeys.paused {
		app_hotkeys(app)
	}
}

// What the settings say under a preference's line.
hotkey_problem :: proc(app: ^App, name: string) -> string {
	for pref, source in SHORTCUT_PREFS { if pref == name { return app.hotkeys.problems[source] } }
	return ""
}

hotkeys_free :: proc(hk: ^Hotkeys) {
	for p in hk.problems { delete(p) }
	hk^ = {}
}

// The preferences recorded as key combinations in the settings.
HOTKEY_PREF_NAMES := [?]string{"shortcut.region", "shortcut.screen", "shortcut.window"}
