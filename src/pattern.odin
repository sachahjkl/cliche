package cliche

// The name of a saved picture, from the save.name pattern. Pure: the worker gives it the local time (stamp_now in
// save.odin reads the time zone) and checks the disk for a name already taken (name_numbered).

import "core:fmt"
import "core:strings"

// A local date and time.
Stamp :: struct { year, month, day, hour, minute, second, milli: int }

// The pattern's fields:
//   %Y year (4 digits)   %m month   %d day   %H hour   %M minute   %S second   (2 digits each)
//   %f milliseconds (3 digits)   %s the source (region, screen, window)   %% a %
// Another %x is kept as it is. The result is one file name: a separator or a character Windows refuses in a name
// becomes '-', and ".png" is added when the name does not end with it. An empty result is "cliche.png".
name_expand :: proc(pattern: string, t: Stamp, source: Source, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(pattern); i += 1 {
		c := pattern[i]
		if c != '%' || i + 1 == len(pattern) { name_write_byte(&b, c); continue }
		i += 1
		switch pattern[i] {
		case 'Y': fmt.sbprintf(&b, "%04d", t.year)
		case 'm': fmt.sbprintf(&b, "%02d", t.month)
		case 'd': fmt.sbprintf(&b, "%02d", t.day)
		case 'H': fmt.sbprintf(&b, "%02d", t.hour)
		case 'M': fmt.sbprintf(&b, "%02d", t.minute)
		case 'S': fmt.sbprintf(&b, "%02d", t.second)
		case 'f': fmt.sbprintf(&b, "%03d", t.milli)
		case 's': strings.write_string(&b, SOURCE_NAMES[source])
		case '%': strings.write_byte(&b, '%')
		case:
			strings.write_byte(&b, '%')
			name_write_byte(&b, pattern[i])
		}
	}
	name := strings.trim_space(strings.to_string(b))
	// (a name of dots alone would be the folder or its parent)
	if strings.trim(name, ".") == "" { name = "cliche" }
	if !strings.has_suffix(name, ".png") { return strings.concatenate({name, ".png"}, allocator) }
	return strings.clone(name, allocator)
}

@(private = "file")
name_write_byte :: proc(b: ^strings.Builder, c: u8) {
	switch c {
	case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 ..< 32, 127: strings.write_byte(b, '-')
	case: strings.write_byte(b, c)
	}
}

// The name with " (n)" before its extension: the n-th try when the name is taken. n <= 1: the name itself.
name_numbered :: proc(name: string, n: int, allocator := context.allocator) -> string {
	if n <= 1 { return strings.clone(name, allocator) }
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 { return fmt.aprintf("%s (%d)", name, n, allocator = allocator) }
	return fmt.aprintf("%s (%d)%s", name[:dot], n, name[dot:], allocator = allocator)
}
