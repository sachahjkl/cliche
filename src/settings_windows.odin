#+build windows
package cliche

// Windows gives a program hotkeys of its own (platform.hotkey_register): one per source. platform.Key has no Print
// Screen, so the defaults are Ctrl+Shift and a digit.

import "core:strings"
import config "gt:config"

PREF_DEFS_SYSTEM := [?]config.Def{
	{name = "shortcut.region", category = "shortcuts", description = "The keys that start a region capture from any program. In the settings, click the field and press them.", kind = .String, default = {s = "Ctrl+Shift+4"}, tags = {"hotkey", "keybinding", "keys"}},
	{name = "shortcut.screen", category = "shortcuts", description = "The keys that capture the screen under the pointer.", kind = .String, default = {s = "Ctrl+Shift+3"}, tags = {"hotkey", "keybinding", "keys", "monitor"}},
	{name = "shortcut.window", category = "shortcuts", description = "The keys that capture the window in front.", kind = .String, default = {s = "Ctrl+Shift+5"}, tags = {"hotkey", "keybinding", "keys"}},
}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {
	s.shortcuts[.Region] = strings.clone(config.string_of(p, "shortcut.region"), allocator)
	s.shortcuts[.Screen] = strings.clone(config.string_of(p, "shortcut.screen"), allocator)
	s.shortcuts[.Window] = strings.clone(config.string_of(p, "shortcut.window"), allocator)
}

SHORTCUTS_NOTE :: ""
