#+build !windows
package cliche

// Elsewhere a program has no hotkeys of its own: the compositor binds keys to commands (`cliche --region`), which come
// to the running cliche as messages (commands.odin).

Hotkeys :: struct {}

hotkey_source :: proc(id: int) -> (s: Source, ok: bool) { return }
app_hotkeys :: proc(app: ^App) {}
app_hotkeys_follow :: proc(app: ^App) {}
hotkey_problem :: proc(app: ^App, name: string) -> string { return "" }
hotkeys_free :: proc(hk: ^Hotkeys) {}

HOTKEY_PREF_NAMES := [0]string{}
