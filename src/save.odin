package cliche

// A picture written as a PNG file, on the worker: whole (a reader never sees half a file), under a name of the pattern
// that no file has yet. A workflow's Save node (workflow_ops.odin) and the editor's Ctrl+S (Job_Save) write with it.

import "core:os"
import "core:strings"
import "core:time"
import "core:time/timezone"
import "gt:fsx"
import png "gt:png"

// Names tried before saving gives up (a pattern with no time in it fills a folder fast).
NAME_TRIES :: 1000

// The outcome of a Job_Save (the editor's Ctrl+S): the file written (owned, "" when not done).
Saved :: struct {
	path:  string,
	error: Flow_Error,
}

// Runs the job and frees what it holds.
save_shot :: proc(j: ^Job_Save) -> (out: Saved) {
	defer job_free_save(j)
	file := png.encode(j.shot.rgba, j.shot.size.x, j.shot.size.y, .Small)
	defer delete(file)
	if file == nil { out.error = .Empty; return }
	pattern := j.pattern != "" ? j.pattern : DEFAULT_NAME_PATTERN
	name := name_expand(pattern, stamp_now(), j.shot.source, context.temp_allocator)
	out.path, out.error = save_file(file, j.folder, name)
	return
}

// `file` in the folder (empty: the default one) under `name`, or the first free "name (n)". path: owned.
save_file :: proc(file: []u8, folder_pref, name: string) -> (path: string, err: Flow_Error) {
	folder := folder_pref != "" ? strings.clone(folder_pref, context.temp_allocator) : save_folder_default(context.temp_allocator)
	if os.make_directory_all(folder) != nil && !folder_exists(folder) { return "", .Not_Saved }
	for n in 1 ..= NAME_TRIES {
		try := strings.concatenate({folder, "/", name_numbered(name, n, context.temp_allocator)}, context.temp_allocator)
		if os.exists(try) { continue }
		if !fsx.write_atomic(try, file, flush = true) { return "", .Not_Saved }
		return strings.clone(try), .None
	}
	return "", .Not_Saved
}

@(private = "file")
job_free_save :: proc(j: ^Job_Save) {
	shot_free(&j.shot)
	delete(j.folder)
	delete(j.pattern)
}

// The local date and time now. It reads the time zone's file: the worker calls it.
stamp_now :: proc() -> Stamp {
	now := time.now()
	dt, ok := time.time_to_datetime(now)
	if !ok { return {} }
	if region, loaded := timezone.region_load("local", context.temp_allocator); loaded {
		if local, converted := timezone.datetime_to_tz(dt, region); converted { dt = local }
	}
	return {
		year = int(dt.date.year), month = int(dt.date.month), day = int(dt.date.day),
		hour = int(dt.time.hour), minute = int(dt.time.minute), second = int(dt.time.second),
		milli = int(dt.time.nano / 1_000_000),
	}
}

// Writes `data` to `path` whole, its folder made first.
write_file :: proc(path: string, data: []u8) -> bool {
	if slash := strings.last_index_any(path, "/\\"); slash > 0 { _ = os.make_directory_all(path[:slash]) }
	return fsx.write_atomic(path, data)
}
