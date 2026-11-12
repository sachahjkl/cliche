#+build windows
package cliche

import "core:os"
import "core:strings"

// The history's file: in the local application data, which does not roam with the profile (its paths are this
// machine's). It reads the environment: the worker calls it.
history_file :: proc(allocator := context.allocator) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if local == "" { return "" }
	return strings.concatenate({local, "\\", APP_NAME, "\\history"}, allocator)
}
