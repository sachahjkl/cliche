package cliche

// A table of commands for a palette or a sheet of keys, kept between frames in its own memory: made again only when
// what it depends on changes (its owner compares its own key), never at each frame.

import "base:runtime"
import "core:mem/virtual"
import "gt:ui"

Palette_Table :: struct {
	arena:    virtual.Arena,
	commands: []ui.Command,
	disabled: []bool,     // per command; its owner fills the part that changes with the app's state
	names:    []string,   // per command after the actions: the preference it names (the main palette's)
	version:  u64,        // raised at each making: the palette's or the sheet's version (0: not made)
}

// Frees the last making and returns the allocator of the next one: the table's version goes up.
palette_table_remake :: proc(t: ^Palette_Table) -> runtime.Allocator {
	virtual.arena_free_all(&t.arena)
	t.commands, t.disabled, t.names = nil, nil, nil
	t.version += 1
	return virtual.arena_allocator(&t.arena)
}

palette_table_destroy :: proc(t: ^Palette_Table) {
	virtual.arena_destroy(&t.arena)
	t^ = {}
}
