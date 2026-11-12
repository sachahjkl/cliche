package cliche

// Screen recording: an MP4 video (H.264) or an animated GIF of a region, a screen or a window, until it is stopped.
//
// The recording flow is a state machine of its own, beside the capture flow (flow.odin), pure and tested without a
// window (record_test.odin):
//
//   Idle -> Choosing -> Ready -> Starting -> Recording -> Stopping -> Done | Failed -> Idle
//                         \-> Idle (cancelled)          \-> Discarding -> Idle (cancelled: the file deleted)
//
// Choosing: the region on the frozen desktop, as a screenshot's. Ready: the region is chosen and nothing records yet;
// the record overlay (record_overlay.odin) frames it, with a Record button: the user starts the recording.
//
// The recorder runs on a thread of its own, not the worker's: a recording lasts, and the worker must stay free for
// screenshots meanwhile. It opens its own capture session (gt:capture's session belongs to the thread that opened it),
// a stream of the source (capture.stream_open), and encodes each frame: gt:h264 then gt:mux into a fragmented MP4 (a
// crash leaves what was recorded playable), or gt:gif at a lower rate, downscaled. The file is written as
// "<name>.part" and renamed at the end: a reader never takes a half file for a whole one.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import capture "gt:capture"
import gif "gt:gif"
import h264 "gt:h264"
import mux "gt:mux"

Record_Format :: enum u8 { Mp4, Gif }

RECORD_FORMAT_EXTENSIONS := [Record_Format]string{.Mp4 = ".mp4", .Gif = ".gif"}

// Why a recording failed.
Record_Error :: enum u8 {
	None,
	Unsupported,   // this desktop cannot stream the source (the portal backend, a window with wlr-screencopy)
	Denied,
	Gone,          // the screen or the window went away
	Failed,        // the system stopped the capture
	No_Encoder,    // no H.264 encoder on this system (no GPU encoder, no openh264)
	Encoder,       // the encoder refused a frame
	Empty,         // stopped before the first frame
	Not_Saved,     // the file could not be written
}

RECORD_ERROR_TEXT := [Record_Error]string{
	.None        = "",
	.Unsupported = "this desktop offers no way to record this",
	.Denied      = "the recording was refused",
	.Gone        = "the screen or the window is gone",
	.Failed      = "the system stopped the recording",
	.No_Encoder  = "this system has no H.264 encoder (a GPU's, or openh264)",
	.Encoder     = "the video encoder failed",
	.Empty       = "the recording was stopped before it began",
	.Not_Saved   = "the recording could not be saved",
}

////////////////////////////////
// The flow

Record_Idle       :: struct {}
Record_Choosing   :: struct { format: Record_Format }                  // the overlay shows the frozen desktop
Record_Ready      :: struct { format: Record_Format }                  // the region chosen: the Record button waits
Record_Starting   :: struct { format: Record_Format }                  // the recorder opens the stream and the encoder
Record_Recording  :: struct { format: Record_Format, elapsed_ms: i64 }
Record_Stopping   :: struct { format: Record_Format }                  // the last frames encoded, the file closed
Record_Discarding :: struct { format: Record_Format }                  // the recorder stops and deletes its file
Record_Done       :: struct { format: Record_Format }
Record_Failed     :: struct { format: Record_Format, error: Record_Error }

Record_Flow :: union #no_nil {
	Record_Idle, Record_Choosing, Record_Ready, Record_Starting, Record_Recording, Record_Stopping, Record_Discarding,
	Record_Done, Record_Failed,
}

Record_Trigger   :: struct { format: Record_Format }   // `cliche --record`, `--record-gif`, the tray, a shortcut
Record_Chosen    :: struct {}                          // the user took a rectangle: Ready
Record_Format_Set :: struct { format: Record_Format }  // the format chosen on the overlay, while Ready
Record_Start     :: struct {}                          // the Record button, the tray: the recorder starts
Record_Cancelled :: struct {}                          // Escape on an overlay, Cancel while Ready
Record_Started   :: struct {}                          // the recorder has its first frame
Record_Progress  :: struct { elapsed_ms: i64 }
Record_Stop      :: struct {}                          // the Stop button, the tray
Record_Discard   :: struct {}                          // Cancel while recording: nothing is kept
Record_Finished  :: struct {}                          // the recorder ended: the file written (a stop, the maximum length), or deleted
Record_Fail      :: struct { error: Record_Error }
Record_Reset     :: struct {}                          // the outcome was told

Record_Event :: union {
	Record_Trigger, Record_Chosen, Record_Format_Set, Record_Start, Record_Cancelled, Record_Started, Record_Progress,
	Record_Stop, Record_Discard, Record_Finished, Record_Fail, Record_Reset,
}

// The state after `e` in `r`. ok false: `e` means nothing in `r`, and `r` stays. The same command walks the flow: a
// trigger chooses the region, again it starts the recording, again it stops it.
record_step :: proc(r: Record_Flow, e: Record_Event) -> (next: Record_Flow, ok: bool) {
	switch s in r {
	case Record_Idle, Record_Done, Record_Failed:
		#partial switch v in e {
		case Record_Trigger: return Record_Choosing{v.format}, true
		case Record_Reset:
			if _, idle := r.(Record_Idle); idle { break }
			return Record_Idle{}, true
		}
	case Record_Choosing:
		#partial switch v in e {
		case Record_Chosen:    return Record_Ready{s.format}, true
		case Record_Cancelled: return Record_Idle{}, true
		case Record_Fail:      return Record_Failed{s.format, v.error}, true
		}
	case Record_Ready:
		#partial switch v in e {
		case Record_Format_Set:           return Record_Ready{v.format}, true
		case Record_Start, Record_Trigger: return Record_Starting{s.format}, true
		case Record_Cancelled:            return Record_Idle{}, true
		case Record_Fail:                 return Record_Failed{s.format, v.error}, true
		}
	case Record_Starting:
		#partial switch v in e {
		case Record_Started:              return Record_Recording{s.format, 0}, true
		case Record_Trigger, Record_Stop: return Record_Stopping{s.format}, true
		case Record_Discard:              return Record_Discarding{s.format}, true
		case Record_Finished:             return Record_Done{s.format}, true
		case Record_Fail:                 return Record_Failed{s.format, v.error}, true
		}
	case Record_Recording:
		#partial switch v in e {
		case Record_Progress:             return Record_Recording{s.format, max(v.elapsed_ms, s.elapsed_ms)}, true
		case Record_Trigger, Record_Stop: return Record_Stopping{s.format}, true
		case Record_Discard:              return Record_Discarding{s.format}, true
		case Record_Finished:             return Record_Done{s.format}, true
		case Record_Fail:                 return Record_Failed{s.format, v.error}, true
		}
	case Record_Stopping:
		#partial switch v in e {
		case Record_Finished: return Record_Done{s.format}, true
		case Record_Fail:     return Record_Failed{s.format, v.error}, true
		}
	case Record_Discarding:
		// (whatever the recorder says at its end: nothing was kept, nothing is told)
		#partial switch _ in e {
		case Record_Finished, Record_Fail: return Record_Idle{}, true
		}
	}
	return r, false
}

// A recording is chosen, ready, starting, running or ending: a trigger goes on with it rather than starting another.
record_busy :: proc(r: Record_Flow) -> bool {
	#partial switch _ in r {
	case Record_Choosing, Record_Ready, Record_Starting, Record_Recording, Record_Stopping, Record_Discarding: return true
	}
	return false
}

// The recorder runs (the tray shows it, a trigger stops it).
record_running :: proc(r: Record_Flow) -> bool {
	#partial switch _ in r {
	case Record_Starting, Record_Recording, Record_Stopping, Record_Discarding: return true
	}
	return false
}

// The region is chosen and the Record button waits.
record_ready :: proc(r: Record_Flow) -> bool {
	_, ready := r.(Record_Ready)
	return ready
}

// The format of the recording under way (Mp4 at rest).
record_format :: proc(r: Record_Flow) -> Record_Format {
	switch s in r {
	case Record_Idle:       return .Mp4
	case Record_Choosing:   return s.format
	case Record_Ready:      return s.format
	case Record_Starting:   return s.format
	case Record_Recording:  return s.format
	case Record_Stopping:   return s.format
	case Record_Discarding: return s.format
	case Record_Done:       return s.format
	case Record_Failed:     return s.format
	}
	return .Mp4
}

// The recording's error for a gt:capture error.
record_error_of :: proc(e: capture.Error) -> Record_Error {
	switch e {
	case .None:        return .None
	case .Unsupported: return .Unsupported
	case .Denied:      return .Denied
	case .Gone:        return .Gone
	case .Failed:      return .Failed
	}
	return .Failed
}

////////////////////////////////
// Pure helpers

// The size a GIF is made at: the frames' size, scaled down to `max_width` when wider (the height in proportion, at
// least 1). 0: no limit. A GIF of a whole 4K screen is large and slow to play; an MP4 keeps the frames' size.
gif_size :: proc(width, height, max_width: int) -> (w, h: int) {
	if max_width <= 0 || width <= max_width { return width, height }
	return max_width, max(1, (height * max_width + width / 2) / width)
}

// `src` (BGRA, `sw` x `sh`, rows `stride` bytes apart) scaled down to `dw` x `dh` into `dst` (packed rows): each pixel
// the mean of the source pixels it covers, so that text stays readable, not the nearest one.
scale_down :: proc(dst: []u8, dw, dh: int, src: []u8, sw, sh, stride: int) #no_bounds_check {
	if dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0 || len(dst) < dw * dh * 4 { return }
	for y in 0 ..< dh {
		y0 := y * sh / dh
		y1 := max((y + 1) * sh / dh, y0 + 1)
		for x in 0 ..< dw {
			x0 := x * sw / dw
			x1 := max((x + 1) * sw / dw, x0 + 1)
			sum: [4]u32
			for sy in y0 ..< y1 {
				row := src[sy * stride:]
				for sx in x0 ..< x1 {
					p := row[sx * 4:][:4]
					sum += [4]u32{u32(p[0]), u32(p[1]), u32(p[2]), u32(p[3])}
				}
			}
			n := u32((y1 - y0) * (x1 - x0))
			d := dst[(y * dw + x) * 4:][:4]
			for c in 0 ..< 4 { d[c] = u8((sum[c] + n / 2) / n) }
		}
	}
}

// `src` (`sw` x `sh`, rows `stride` bytes apart) copied into `dst`, a `dw` x `dh` frame (packed rows): what is beyond is
// cut, what is missing is black. A window that changes size during a recording keeps the video's size.
copy_fit :: proc(dst: []u8, dw, dh: int, src: []u8, sw, sh, stride: int) {
	if len(dst) < dw * dh * 4 { return }
	cw, ch := min(dw, sw), min(dh, sh)
	if cw < dw || ch < dh { runtime.mem_zero(raw_data(dst), dw * dh * 4) }
	if cw <= 0 { return }
	for y in 0 ..< ch {
		copy(dst[y * dw * 4:][:cw * 4], src[y * stride:][:cw * 4])
	}
}

// The delay of a GIF frame shown from `from` to `to` (nanoseconds since the start), in hundredths of a second. Both ends
// are rounded on one grid, so the delays add up to the length without drift; at least 2 (browsers show 0 and 1 as 10).
gif_delay_cs :: proc(from, to: i64) -> int {
	CS :: i64(10 * time.Millisecond)
	return max(int((to + CS / 2) / CS - (from + CS / 2) / CS), 2)
}

// The duration of a video packet shown from `from` to `to` (nanoseconds), in seconds; one frame at `fps` when the
// timestamps do not say more (the last packet, two with one time).
packet_duration :: proc(from, to: i64, fps: int) -> f64 {
	if to > from { return f64(to - from) / f64(time.Second) }
	return 1 / f64(max(fps, 1))
}

// The file name of a recording: save.name's pattern (the screenshots'), with the format's extension for ".png".
record_name :: proc(pattern: string, t: Stamp, source: Source, format: Record_Format, allocator := context.allocator) -> string {
	name := name_expand(pattern, t, source, context.temp_allocator)
	name = strings.trim_suffix(name, ".png")
	return strings.concatenate({name, RECORD_FORMAT_EXTENSIONS[format]}, allocator)
}

// "00:07", "12:34", "1:02:03": the clock of a recording under way (the overlay, the tray's tooltip).
record_clock_text :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	s := max(ms, 0) / 1000
	if s >= 3600 { return fmt.aprintf("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, allocator = allocator) }
	return fmt.aprintf("%02d:%02d", s / 60, s % 60, allocator = allocator)
}

// "0:07", "12:34", "1:02:03".
record_elapsed_text :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	s := max(ms, 0) / 1000
	if s >= 3600 { return fmt.aprintf("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, allocator = allocator) }
	return fmt.aprintf("%d:%02d", s / 60, s % 60, allocator = allocator)
}

// "340 KB", "12.5 MB".
size_text :: proc(bytes: i64, allocator := context.temp_allocator) -> string {
	switch {
	case bytes < 1000 * 1000:        return fmt.aprintf("%d KB", (bytes + 999) / 1000, allocator = allocator)
	case bytes < 1000 * 1000 * 1000: return fmt.aprintf("%.1f MB", f64(bytes) / 1e6, allocator = allocator)
	}
	return fmt.aprintf("%.2f GB", f64(bytes) / 1e9, allocator = allocator)
}

// The notification's body at the end of a recording: where it is, its size and its length.
record_notice_body :: proc(path: string, bytes, length_ms: i64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s\n%s, %s", path, size_text(bytes), record_elapsed_text(length_ms), allocator = allocator)
}

////////////////////////////////
// The recorder

// How long the recorder waits for a frame before it looks again at a stop and at the maximum length.
@(private = "file") RECORD_POLL :: 100 * time.Millisecond
// How often the elapsed time is posted to the interface (the tray's text).
@(private = "file") RECORD_TICK :: time.Second

// What a recording is asked to be. The strings are the recorder's once it is started.
Record_Job :: struct {
	format:    Record_Format,
	source:    capture.Stream_Source,
	kind:      Source,          // the source's word in the file name (%s)
	fps:       int,             // MP4: frames a second at the most
	gif_fps:   int,
	gif_width: int,             // the GIF's largest width (0: the frames' own)
	cursor:    bool,            // the pointer drawn in, where the desktop can
	max_ms:    i64,             // the longest recording, in milliseconds (0: until stopped)
	folder:    string,          // "": the default folder (save_folder_default)
	pattern:   string,          // save.name
}

// The recorder has its first frame and its file (the size of the picture written).
Record_Opened :: struct { width, height: int }
// The time since the first frame, and the bytes encoded so far.
Record_Tick :: struct { elapsed_ms: i64, bytes: i64 }
// The recording is over: its file (owned; "" when nothing was saved, or when it was cancelled: then with no error), its
// size and its length.
Record_Ended :: struct { error: Record_Error, path: string, bytes: i64, length_ms: i64 }

Record_Message :: union { Record_Opened, Record_Tick, Record_Ended }

Recorder :: struct {
	thread:    ^thread.Thread,
	job:       Record_Job,                // the recorder thread's
	stop:      bool,                      // atomic: asked by the interface's thread
	cancel:    bool,                      // atomic: with `stop`, the file is deleted, not saved
	mutex:     sync.Mutex,
	messages:  [dynamic]Record_Message,   // guarded by `mutex`
	wake:      proc(user: rawptr),
	wake_user: rawptr,
}

// Starts a recording of `job` (its strings are the recorder's now). False: the thread cannot start (the job is freed).
recorder_start :: proc(r: ^Recorder, job: Record_Job, wake: proc(user: rawptr), wake_user: rawptr) -> bool {
	if r.thread != nil { record_job_free(&r.job) }
	r.job = job
	sync.atomic_store(&r.stop, false)
	sync.atomic_store(&r.cancel, false)
	r.wake, r.wake_user = wake, wake_user
	r.thread = thread.create(recorder_run)
	if r.thread == nil {
		record_job_free(&r.job)
		return false
	}
	r.thread.data = r
	thread.start(r.thread)
	return true
}

// Asks the recording to end: the recorder closes its file and posts Record_Ended. Returns at once.
recorder_stop :: proc(r: ^Recorder) {
	sync.atomic_store(&r.stop, true)
}

// Asks the recording to end with nothing kept: the recorder deletes its ".part" file and posts a Record_Ended with no
// path and no error. Returns at once.
recorder_cancel :: proc(r: ^Recorder) {
	sync.atomic_store(&r.cancel, true)
	sync.atomic_store(&r.stop, true)
}

// Waits for the recorder's thread to end (at once after its Record_Ended; at the quit, once its file is closed), then
// frees what it held. The messages not taken are dropped.
recorder_join :: proc(r: ^Recorder) {
	if r.thread == nil { return }
	sync.atomic_store(&r.stop, true)
	thread.join(r.thread)
	thread.destroy(r.thread)
	r.thread = nil
	record_job_free(&r.job)
	for &m in r.messages { record_message_free(&m) }
	delete(r.messages)
	r.messages = nil
}

// The messages since the last call, in order (temp allocator; what each holds is the caller's).
recorder_take :: proc(r: ^Recorder) -> []Record_Message {
	sync.guard(&r.mutex)
	out := make([]Record_Message, len(r.messages), context.temp_allocator)
	copy(out, r.messages[:])
	clear(&r.messages)
	return out
}

record_message_free :: proc(m: ^Record_Message) {
	if e, ok := m^.(Record_Ended); ok { delete(e.path) }
	m^ = nil
}

@(private = "file")
record_job_free :: proc(j: ^Record_Job) {
	delete(j.folder)
	delete(j.pattern)
	j^ = {}
}

@(private = "file")
recorder_post :: proc(r: ^Recorder, m: Record_Message) {
	sync.mutex_lock(&r.mutex)
	append(&r.messages, m)
	sync.mutex_unlock(&r.mutex)
	r.wake(r.wake_user)
}

@(private = "file")
recorder_run :: proc(t: ^thread.Thread) {
	r := (^Recorder)(t.data)
	ended := record(r)
	recorder_post(r, ended)
	free_all(context.temp_allocator)
}

// One recording, from the stream's first frame to the file renamed. What it allocates outside the temporary
// allocator is freed here; the path given back is the caller's.
@(private = "file")
record :: proc(r: ^Recorder) -> Record_Ended {
	job := &r.job
	s, open_err := capture.open()
	if open_err != .None { return {error = record_error_of(open_err)} }
	defer capture.close(s)
	fps := job.format == .Gif ? job.gif_fps : job.fps
	st, stream_err := capture.stream_open(s, job.source, {fps = fps, cursor = job.cursor})
	if stream_err != .None { return {error = record_error_of(stream_err)} }
	defer capture.stream_close(st)

	// The first frame gives the size of the file's picture; the clock starts with it.
	first: capture.Stream_Frame
	for {
		if sync.atomic_load(&r.cancel) { return {} }
		if sync.atomic_load(&r.stop) { return {error = .Empty} }
		f, ok, err := capture.stream_next(st, RECORD_POLL)
		if err != .None { return {error = record_error_of(err)} }
		if ok { first = f; break }
	}
	started := time.tick_now()

	final, part, named := record_paths(job)
	if !named { return {error = .Not_Saved} }
	defer delete(final)
	defer delete(part)
	k: Record_Sink
	failed := sink_open(&k, job, int(first.width), int(first.height), fps, part)
	if failed == .None { failed = sink_frame(&k, first) }
	if failed != .None {
		sink_free(&k)
		_ = os.remove(part)
		return {error = failed}
	}
	recorder_post(r, Record_Opened{k.width, k.height})

	last_tick := started
	for !sync.atomic_load(&r.stop) {
		elapsed := time.tick_since(started)
		if job.max_ms > 0 && i64(elapsed) >= job.max_ms * i64(time.Millisecond) { break }
		if time.tick_since(last_tick) >= RECORD_TICK {
			last_tick = time.tick_now()
			recorder_post(r, Record_Tick{i64(elapsed / time.Millisecond), k.bytes})
		}
		f, ok, err := capture.stream_next(st, RECORD_POLL)
		// (the source went away, a window closed: what was recorded is kept, as after a stop)
		if err != .None { break }
		if !ok { continue }
		if failed = sink_frame(&k, f); failed != .None {
			sink_free(&k)
			_ = os.remove(part)
			return {error = failed}
		}
		free_all(context.temp_allocator)
	}
	if sync.atomic_load(&r.cancel) {
		sink_free(&k)
		_ = os.remove(part)
		return {}
	}
	end := i64(time.tick_since(started))
	if failed = sink_close(&k, end); failed != .None {
		_ = os.remove(part)
		return {error = failed}
	}
	path := record_rename(part, final)
	if path == "" {
		_ = os.remove(part)
		return {error = .Not_Saved}
	}
	bytes := k.bytes
	if info, err := os.stat(path, context.temp_allocator); err == nil { bytes = info.size }
	return {path = path, bytes = bytes, length_ms = end / i64(time.Millisecond)}
}

// The file's name, free in the folder (neither it nor its ".part" there), and the ".part" written meanwhile (owned).
@(private = "file")
record_paths :: proc(job: ^Record_Job) -> (final, part: string, ok: bool) {
	folder := job.folder != "" ? job.folder : save_folder_default(context.temp_allocator)
	if os.make_directory_all(folder) != nil && !folder_exists(folder) { return }
	name := record_name(job.pattern, stamp_now(), job.kind, job.format, context.temp_allocator)
	for n in 1 ..= NAME_TRIES {
		try := strings.concatenate({folder, "/", name_numbered(name, n, context.temp_allocator)}, context.temp_allocator)
		try_part := strings.concatenate({try, ".part"}, context.temp_allocator)
		if os.exists(try) || os.exists(try_part) { continue }
		return strings.clone(try), strings.clone(try_part), true
	}
	return
}

// `part` renamed to `final`, or to the next free name when a file took `final` meanwhile. The path (owned); "": not
// renamed.
@(private = "file")
record_rename :: proc(part, final: string) -> string {
	dot := strings.last_index_byte(final, '.')
	for n in 1 ..= NAME_TRIES {
		try := final
		if n > 1 {
			try = dot > 0 ? fmt.tprintf("%s (%d)%s", final[:dot], n, final[dot:]) : fmt.tprintf("%s (%d)", final, n)
		}
		if os.exists(try) { continue }
		if os.rename(part, try) != nil { return "" }
		return strings.clone(try)
	}
	return ""
}

// Where the frames go: an H.264 encoder and an MP4 muxer, or a GIF encoder and its file.
@(private = "file")
Record_Sink :: struct {
	format:        Record_Format,
	source_size:   [2]int,         // the first frame's: a later frame of another size is fitted to it
	width, height: int,            // the file's picture
	fps:           int,
	fit:           [dynamic]u8,
	bytes:         i64,            // encoded so far

	// MP4
	encoder:       ^h264.Encoder,
	muxer:         ^mux.Muxer,
	track:         mux.Track,
	held:          [dynamic]u8,    // the last packet: its duration is known when the next one comes
	held_at:       i64,
	held_key:      bool,
	has_held:      bool,

	// GIF
	gif:           gif.Encoder,
	gif_open:      bool,
	file:          ^os.File,
	pending:       [dynamic]u8,    // the last frame at the GIF's size: its delay is known when the next one comes
	pending_at:    i64,
	has_pending:   bool,
	scaled:        [dynamic]u8,
}

@(private = "file")
sink_open :: proc(k: ^Record_Sink, job: ^Record_Job, width, height, fps: int, path: string) -> Record_Error {
	k.format, k.source_size, k.fps = job.format, {width, height}, fps
	switch job.format {
	case .Mp4:
		encoder, err := h264.open(width, height, fps)
		if err != .None { return err == .Unavailable ? .No_Encoder : .Encoder }
		k.encoder = encoder
		k.width, k.height = encoder.width, encoder.height
		muxer, mux_err := mux.mp4_open_file(path, {fast_start = .Fragmented})
		if mux_err != .None { return .Not_Saved }
		k.muxer = muxer
		track, track_err := mux.add_video_track(muxer, {codec = .AVC, width = encoder.width, height = encoder.height, frame_rate = f64(fps)})
		if track_err != .None { return .Encoder }
		k.track = track
	case .Gif:
		k.width, k.height = gif_size(width, height, job.gif_width)
		file, file_err := os.create(path)
		if file_err != nil { return .Not_Saved }
		k.file = file
		// (streamed to the file: a long recording is never held whole in memory)
		if !gif.begin(&k.gif, k.width, k.height, 0, {}, sink_gif_write, k) { return .Not_Saved }
		k.gif_open = true
		resize(&k.pending, k.width * k.height * 4)
		resize(&k.scaled, k.width * k.height * 4)
	}
	return .None
}

@(private = "file")
sink_gif_write :: proc(user: rawptr, data: []u8) -> bool {
	k := (^Record_Sink)(user)
	n, err := os.write(k.file, data)
	k.bytes += i64(max(n, 0))
	return err == nil && n == len(data)
}

@(private = "file")
sink_frame :: proc(k: ^Record_Sink, f: capture.Stream_Frame) -> Record_Error {
	sw, sh := k.source_size.x, k.source_size.y
	pixels, stride := f.pixels, int(f.stride)
	if int(f.width) != sw || int(f.height) != sh {
		resize(&k.fit, sw * sh * 4)
		copy_fit(k.fit[:], sw, sh, f.pixels, int(f.width), int(f.height), stride)
		pixels, stride = k.fit[:], sw * 4
	}
	switch k.format {
	case .Mp4:
		packets, err := h264.encode(k.encoder, {pixels = pixels, width = sw, height = sh, stride = stride, format = .BGRA}, time.Duration(f.timestamp))
		if err != .None { return .Encoder }
		return sink_packets(k, packets)
	case .Gif:
		if k.width == sw && k.height == sh {
			copy_fit(k.scaled[:], k.width, k.height, pixels, sw, sh, stride)
		} else {
			scale_down(k.scaled[:], k.width, k.height, pixels, sw, sh, stride)
		}
		if k.has_pending && !gif.add_frame(&k.gif, k.pending[:], 0, gif_delay_cs(k.pending_at, f.timestamp)) { return .Not_Saved }
		k.pending, k.scaled = k.scaled, k.pending
		k.pending_at, k.has_pending = f.timestamp, true
	}
	return .None
}

// The encoder's packets to the muxer, each once the next one says how long it lasts.
@(private = "file")
sink_packets :: proc(k: ^Record_Sink, packets: []h264.Packet) -> Record_Error {
	for p in packets {
		at := i64(p.timestamp)
		if k.has_held {
			if mux.add_packet(k.muxer, k.track, k.held[:], f64(k.held_at) / f64(time.Second), packet_duration(k.held_at, at, k.fps), k.held_key) != .None {
				return .Not_Saved
			}
		}
		resize(&k.held, len(p.data))
		copy(k.held[:], p.data)
		k.held_at, k.held_key, k.has_held = at, p.keyframe, true
		k.bytes += i64(len(p.data))
	}
	return .None
}

// The last frame lasts until `end` (nanoseconds since the first): the file is written whole and closed.
@(private = "file")
sink_close :: proc(k: ^Record_Sink, end: i64) -> (err: Record_Error) {
	defer sink_free(k)
	switch k.format {
	case .Mp4:
		packets, flush_err := h264.flush(k.encoder)
		if flush_err == .None {
			if e := sink_packets(k, packets); e != .None { return e }
		}
		if k.has_held {
			if mux.add_packet(k.muxer, k.track, k.held[:], f64(k.held_at) / f64(time.Second), packet_duration(k.held_at, end, k.fps), k.held_key) != .None {
				return .Not_Saved
			}
		}
		_, finalize_err := mux.finalize(k.muxer)
		k.muxer = nil   // (finalize freed it)
		if finalize_err != .None { return .Not_Saved }
	case .Gif:
		if k.has_pending && !gif.add_frame(&k.gif, k.pending[:], 0, gif_delay_cs(k.pending_at, end)) { return .Not_Saved }
		_, ended := gif.end(&k.gif)
		k.gif_open = false   // (end freed it)
		if os.close(k.file) != nil { ended = false }
		k.file = nil
		if !ended { return .Not_Saved }
	}
	return .None
}

@(private = "file")
sink_free :: proc(k: ^Record_Sink) {
	if k.encoder != nil { h264.close(k.encoder) }
	if k.muxer != nil { mux.destroy(k.muxer) }
	if k.gif_open { gif.destroy(&k.gif) }
	if k.file != nil { os.close(k.file) }
	delete(k.fit)
	delete(k.held)
	delete(k.pending)
	delete(k.scaled)
	bytes := k.bytes   // (what record reports when the file cannot be read back)
	k^ = {}
	k.bytes = bytes
}
