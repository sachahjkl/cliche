package cliche

// The Save action, on the worker: the PNG file encoded and written whole (a reader never sees half a file), in the
// folder of save.folder, under a name of save.name that no file has yet.

import "core:os"
import "core:strings"
import "core:time"
import "core:time/timezone"
import "gt:fsx"
import "gt:platform"
import png "gt:png"

// Names tried before saving gives up (a pattern with no time in it fills a folder fast).
NAME_TRIES :: 1000

// The outcome of a Job_Save: the file written, the URL the host gave (each owned, "" when not asked or not done).
Saved :: struct {
	path:           string,
	url:            string,
	upload_problem: string,   // owned: why the upload failed ("" none)
	from_editor:    bool,     // the editor's Ctrl+S: told to the editor, not to the capture's flow
	size:           [2]int,   // the picture's, in pixels (the history keeps it)
	bytes:          i64,      // the PNG's
	error:          Flow_Error,
}

// Runs the job and frees what it holds: the PNG encoded once, written when save.* asks, then uploaded when after.upload
// asks (a failed upload keeps the file: the flow does not fail for it).
save_shot :: proc(j: ^Job_Save) -> (out: Saved) {
	defer job_free_save(j)
	if !j.save && !j.upload { return }
	file := png.encode(j.shot.rgba, j.shot.size.x, j.shot.size.y, j.fast ? .Fast : .Small)
	defer delete(file)
	if file == nil { out.error = .Empty; return }
	out.size, out.bytes = j.shot.size, i64(len(file))
	out.from_editor = j.from_editor
	name := name_expand(j.pattern, stamp_now(), j.shot.source, context.temp_allocator)
	if j.save {
		out.path, out.error = save_file(file, j.folder, name, j.reveal)
		if out.error != .None { return }
	}
	if j.upload {
		list, problems := uploaders_load(context.temp_allocator)
		_ = problems
		u, _ := uploader_find(list, j.uploader)
		if u == nil { out.upload_problem = strings.clone("no uploader is set up"); return }
		base := out.path != "" ? out.path[strings.last_index_any(out.path, "/\\") + 1:] : name
		out.url, out.upload_problem = upload_shot(u^, file, base)
		if out.upload_problem != "" && !j.save { out.error = .Not_Uploaded }
	}
	return
}

// `file` in the folder (empty: the default one) under `name`, or the first free "name (n)". path: owned.
@(private = "file")
save_file :: proc(file: []u8, folder_pref, name: string, reveal: bool) -> (path: string, err: Flow_Error) {
	folder := folder_pref != "" ? strings.clone(folder_pref, context.temp_allocator) : save_folder_default(context.temp_allocator)
	if os.make_directory_all(folder) != nil && !folder_exists(folder) { return "", .Not_Saved }
	for n in 1 ..= NAME_TRIES {
		try := strings.concatenate({folder, "/", name_numbered(name, n, context.temp_allocator)}, context.temp_allocator)
		if os.exists(try) { continue }
		if !fsx.write_atomic(try, file, flush = true) { return "", .Not_Saved }
		if reveal { _ = platform.reveal_in_folder(try) }
		return strings.clone(try), .None
	}
	return "", .Not_Saved
}

@(private = "file")
job_free_save :: proc(j: ^Job_Save) {
	shot_free(&j.shot)
	delete(j.folder)
	delete(j.pattern)
	delete(j.uploader)
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
