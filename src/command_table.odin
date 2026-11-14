package cliche

// A table of commands for a sheet of keys, kept between frames in its own memory: made again only when what it depends
// on changes (its owner compares its own key), never at each frame. (The palettes are fed by sources: src/palette.odin.)

import "base:runtime"
import "core:mem/virtual"
import "gt:ui"

Command_Table :: struct {
	arena:    virtual.Arena,
	commands: []ui.Command,
	version:  u64,        // raised at each making: the sheet's version (0: not made)
}

// Frees the last making and returns the allocator of the next one: the table's version goes up.
command_table_remake :: proc(t: ^Command_Table) -> runtime.Allocator {
	virtual.arena_free_all(&t.arena)
	t.commands = nil
	t.version += 1
	return virtual.arena_allocator(&t.arena)
}

command_table_destroy :: proc(t: ^Command_Table) {
	virtual.arena_destroy(&t.arena)
	t^ = {}
}
