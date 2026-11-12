package cliche

// The preferences: one registry (gt:config). The user's file is <config dir>/cliche/prefs; `--pref name=value`
// overrides a preference for one run. Each system adds its own (settings_linux.odin, settings_windows.odin).

import "core:os"
import "core:strings"
import config "gt:config"
import "gt:platform"

APP_NAME :: "cliche"

DEFAULT_NAME_PATTERN :: "cliche-%Y%m%d-%H%M%S.png"

PREF_DEFS := [?]config.Def{
	{name = "save.folder", category = "save", description = "The folder screenshots are saved in. Empty: Pictures/Screenshots when it exists, else Pictures/cliche.", kind = .String, default = {s = ""}, tags = {"directory", "path", "where"}},
	{name = "save.name", category = "save", description = "The name of a saved screenshot: %Y year, %m month, %d day, %H hour, %M minute, %S second, %f milliseconds, %s the source (region, screen, window), %% a %. A taken name gets \" (2)\".", kind = .String, default = {s = DEFAULT_NAME_PATTERN}, tags = {"file name", "pattern", "format"}},
	{name = "after.copy", category = "after", description = "Copy the picture to the clipboard.", kind = .Bool, default = {b = true}, tags = {"clipboard", "paste"}},
	{name = "after.save", category = "after", description = "Save the picture as a PNG file in the folder.", kind = .Bool, default = {b = true}, tags = {"file", "disk", "png"}},
	{name = "after.notify", category = "after", description = "Show a notification that says where the picture went.", kind = .Bool, default = {b = true}, tags = {"toast", "message"}},
	{name = "region.magnifier", category = "region", description = "Show a magnifier near the pointer, with the pointer's position and the selection's size.", kind = .Bool, default = {b = true}, tags = {"zoom", "loupe", "pixel"}},
	{name = "region.confirm_on_release", category = "region", description = "Take the rectangle as soon as the button is released. Off: adjust it with the arrow keys (Shift: resize), then press Enter or click inside it.", kind = .Bool, default = {b = false}, tags = {"fast", "enter"}},
}

// The values the program reads, copied out of the registry (prefs_read).
Settings :: struct {
	folder:            string,   // "": the default folder (save_folder_default)
	name_pattern:      string,
	actions:           After_Capture_Set,
	notify:            bool,
	magnifier:         bool,
	confirm_on_release: bool,
	shortcuts:         [Source]string,   // Windows: the hotkeys, as platform.hotkey_parse reads them
}

prefs_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.config_dir(context.temp_allocator), "/", APP_NAME, "/prefs"}, allocator)
}

// The registry with the user's file and `args`' --pref read in. Returns the arguments that are not preferences.
prefs_open :: proc(p: ^config.Prefs, args: []string) -> (rest: [dynamic]string, problems: [dynamic]string) {
	p^ = config.prefs_make()
	config.register(p, PREF_DEFS[:])
	config.register(p, PREF_DEFS_SYSTEM[:])
	_, file_problems := config.load_file(p, prefs_file(), .User)
	rest, problems = config.apply_args(p, args, context.temp_allocator)
	append(&problems, ..file_problems[:])
	return
}

prefs_read :: proc(p: ^config.Prefs, allocator := context.allocator) -> (s: Settings) {
	s.folder = strings.clone(strings.trim_space(config.string_of(p, "save.folder")), allocator)
	s.name_pattern = strings.clone(config.string_of(p, "save.name"), allocator)
	if config.bool_of(p, "after.copy") { s.actions += {.Copy} }
	if config.bool_of(p, "after.save") { s.actions += {.Save} }
	s.notify = config.bool_of(p, "after.notify")
	s.magnifier = config.bool_of(p, "region.magnifier")
	s.confirm_on_release = config.bool_of(p, "region.confirm_on_release")
	prefs_read_system(p, &s, allocator)
	return
}

settings_free :: proc(s: ^Settings, allocator := context.allocator) {
	delete(s.folder, allocator)
	delete(s.name_pattern, allocator)
	for v in s.shortcuts { delete(v, allocator) }
	s^ = {}
}

// The default folder: Pictures/Screenshots when it exists (where most desktops put theirs), else Pictures/cliche. It reads
// the disk: the worker calls it.
save_folder_default :: proc(allocator := context.allocator) -> string {
	pictures := platform.known_folder_path(.Pictures, context.temp_allocator)
	if pictures == "" {
		home := platform.known_folder_path(.Home, context.temp_allocator)
		pictures = strings.concatenate({home, "/Pictures"}, context.temp_allocator)
	}
	shots := strings.concatenate({pictures, "/Screenshots"}, context.temp_allocator)
	if folder_exists(shots) { return strings.clone(shots, allocator) }
	return strings.concatenate({pictures, "/", APP_NAME}, allocator)
}

folder_exists :: proc(path: string) -> bool { return os.is_dir(path) }
