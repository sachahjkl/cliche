package cliche

// The Save action, on the worker: the PNG file encoded and written whole (a reader never sees half a file), in the
// folder of save.folder, under a name of save.name that no file has yet.

import "core:os"
import "core:strings"
import "core:time"
import "core:time/timezone"
import "gt:fsx"
import png "gt:png"

// Names tried before saving gives up (a pattern with no time in it fills a folder fast).
NAME_TRIES :: 1000

// Runs the job and frees what it holds. path: the file written (owned), "" when the chain does not save.
save_shot :: proc(j: ^Job_Save) -> (path: string, err: Flow_Error) {
	defer job_free_save(j)
	if !j.save { return "", .None }
	folder := j.folder != "" ? strings.clone(j.folder, context.temp_allocator) : save_folder_default(context.temp_allocator)
	if os.make_directory_all(folder) != nil && !folder_exists(folder) { return "", .Not_Saved }
	file := png.encode(j.shot.rgba, j.shot.size.x, j.shot.size.y, .Small)
	defer delete(file)
	if file == nil { return "", .Empty }
	name := name_expand(j.pattern, stamp_now(), j.shot.source, context.temp_allocator)
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
