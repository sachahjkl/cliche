#+build !windows
package cliche

import "core:os"
import "core:strings"

// The history's file: what cliche keeps of its own past belongs to the state folder (XDG Base Directory), not to the
// preferences. It reads the environment: the worker calls it.
history_file :: proc(allocator := context.allocator) -> string {
	state := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if state == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { return "" }
		state = strings.concatenate({home, "/.local/state"}, context.temp_allocator)
	}
	return strings.concatenate({state, "/", APP_NAME, "/history"}, allocator)
}
