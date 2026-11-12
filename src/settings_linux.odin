#+build !windows
package cliche

// Linux has no shortcut of cliche's own: the compositor binds a key to a command (`cliche --region`), which hands it to
// the running cliche (commands.odin). The settings say which commands to bind.

import config "gt:config"

PREF_DEFS_SYSTEM := [0]config.Def{}

prefs_read_system :: proc(p: ^config.Prefs, s: ^Settings, allocator := context.allocator) {}

SHORTCUTS_NOTE :: "Shortcuts: bind keys to these commands in your compositor's configuration: cliche --region, cliche --screen, cliche --window."
