package cliche

// A picture written as a file, on the worker: whole (a reader never sees half a file), under a name of the pattern
// that no file has yet. A workflow's Save node (workflow_ops.odin) and the editor's Ctrl+S (Job_Save) write with it;
// the editor's Save as (Job_Save_As) writes the path chosen in the system's dialog, in the format chosen there
// (save_encode, every format of Save_Format).

import "core:os"
import "core:strings"
import "core:time"
import "core:time/timezone"
import "gt:fsx"
import i18n "gt:i18n"
import pic "gt:image"
import png "gt:png"

// Names tried before saving gives up (a pattern with no time in it fills a folder fast).
NAME_TRIES :: 1000

// The outcome of a Job_Save (the editor's Ctrl+S) or a Job_Save_As: the file written (owned, "" when not done), and
// what went wrong in words when the flow's errors do not say it (owned, "" none: a WebP with no libwebp).
Saved :: struct {
	path:    string,
	error:   Flow_Error,
	problem: string,
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

// The file of `shot` in `format` (`quality`, 1 to 100: JPEG and lossy WebP). file: owned; problem "" when made, else
// why not (translated). On the worker: it is a pass over every pixel.
save_encode :: proc(shot: Shot, format: Save_Format, quality: int) -> (file: []u8, problem: string) {
	if shot.rgba == nil { return nil, i18n.tr("no picture came in") }
	img := pic.Image{pixels = shot.rgba, width = shot.size.x, height = shot.size.y}
	switch format {
	case .Png_Small:     file = png.encode(shot.rgba, shot.size.x, shot.size.y, .Small)
	case .Png_Fast:      file = png.encode(shot.rgba, shot.size.x, shot.size.y, .Fast)
	case .Jpeg:          file = pic.jpeg_encode(img, clamp(quality, 1, 100))
	case .Webp, .Webp_Lossless:
		if !pic.webp_available() { return nil, i18n.tr("this system has no WebP encoder (install libwebp)") }
		file = pic.webp_encode(img, clamp(quality, 1, 100), format == .Webp_Lossless)
	}
	if file == nil { return nil, i18n.tr(FLOW_ERROR_TEXT[.Empty]) }
	return file, ""
}

// The editor's Save as: the formats its dialog offers, in its filters' order, with their names in the preferences
// (save.as_format).
SAVE_AS_FORMATS := [?]Save_Format{.Png_Small, .Jpeg, .Webp}
SAVE_AS_NAMES := [len(SAVE_AS_FORMATS)]string{"png", "jpeg", "webp"}

// The filter's index of a format of the dialog (PNG for one it does not offer).
save_as_index :: proc(f: Save_Format) -> int {
	for x, i in SAVE_AS_FORMATS { if x == f { return i } }
	return 0
}

// The format save.as_format names; PNG for another word.
save_as_format_named :: proc(name: string) -> Save_Format {
	for n, i in SAVE_AS_NAMES { if n == name { return SAVE_AS_FORMATS[i] } }
	return .Png_Small
}

// The path and the format of a Save as, from the dialog's answer: the extension typed decides (".jpg" is a JPEG,
// whatever filter was left selected); with none the filter does, and its extension is added. A path that ends with an
// extension of no format offered keeps it, and gets the filter's format. Temp allocator.
save_as_choice :: proc(path: string, filter: int) -> (out: string, format: Save_Format) {
	format = SAVE_AS_FORMATS[clamp(filter, 0, len(SAVE_AS_FORMATS) - 1)]
	ext := strings.to_lower(file_extension(path), context.temp_allocator)
	switch ext {
	case ".png":           return path, .Png_Small
	case ".jpg", ".jpeg":  return path, .Jpeg
	case ".webp":          return path, .Webp
	case "":               return strings.concatenate({path, SAVE_FORMAT_EXTENSION[format]}, context.temp_allocator), format
	}
	return path, format
}

// ".png" of ".../shot.png"; "" when the name has no dot (a dot of a folder's name is not the file's).
@(private = "file")
file_extension :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_any(path, "/\\"); slash >= 0 { name = path[slash + 1:] }
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 { return "" }
	return name[dot:]
}

// An editor's Save as: the file chosen in the system's dialog, written whole (the dialog asked before replacing one).
save_as_shot :: proc(j: ^Job_Save_As) -> (out: Saved) {
	defer { shot_free(&j.shot); delete(j.path) }
	file, problem := save_encode(j.shot, j.format, j.quality)
	defer delete(file)
	if problem != "" { out.error = .Empty; out.problem = strings.clone(problem); return }
	if !write_file(j.path, file) { out.error = .Not_Saved; return }
	out.path = strings.clone(j.path)
	return
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
