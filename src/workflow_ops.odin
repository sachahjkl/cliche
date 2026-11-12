package cliche

// The worker's part of a run: a node's work on the picture, the disk or the network (Job_Node), done on the worker's
// thread. The input picture is read only (other branches read it too): an operation makes a new picture, and one that
// works in place works on a copy. Every call into gt:image is here.

import "core:math"
import "core:os"
import "core:strings"
import "gt:font"
import "gt:platform"
import pic "gt:image"
import png "gt:png"

// The largest side of a node's thumbnail in the Workflows mode, in pixels.
THUMBNAIL_SIDE :: 192

// Node `node` of run `run`, for the worker. All owned: `n` a copy of the node, `input` a value with its own reference on
// the picture (given back in the result: only the interface's thread lets a picture go).
Job_Node :: struct {
	run:       u64,
	node:      int,
	n:         Workflow_Node,
	input:     Run_Value,
	source:    Source,
	defaults:  Node_Defaults,
	thumbnail: bool,   // the Workflows mode shows this run: a small picture of the output
}

// What a node takes from the settings when its own parameter is empty (owned).
Node_Defaults :: struct {
	folder, pattern, uploader, languages: string,
}

Result_Node :: struct {
	run:       u64,
	node:      int,
	input:     ^Run_Picture,   // the job's reference: the interface lets it go
	result:    Run_Result,     // its message owned
	thumbnail: []u8,           // RGBA (owned; nil: none)
	clipboard_png: []u8,       // Copy image: the picture as a PNG file, for the clipboard (owned): encoded here, not on the interface's thread
	thumbnail_size: [2]int,
}

// A node's thumbnail alone, for one the worker does not run (Capture): its input picture made small.
Job_Thumbnail :: struct { run: u64, node: int, input: Run_Value }
Result_Thumbnail :: struct { run: u64, node: int, input: ^Run_Picture, thumbnail: []u8, thumbnail_size: [2]int }   // (owned; input: the job's reference)

thumbnail_work :: proc(j: ^Job_Thumbnail) -> (out: Result_Thumbnail) {
	out = {run = j.run, node = j.node, input = j.input.picture}
	if out.input != nil { out.thumbnail, out.thumbnail_size = thumbnail_of(out.input.shot) }
	delete(j.input.text)
	return
}

job_node_free :: proc(j: ^Job_Node) {
	node_params_free(&j.n)
	value_free(&j.input)
	node_defaults_free(&j.defaults)
}

node_defaults_free :: proc(d: ^Node_Defaults) {
	delete(d.folder)
	delete(d.pattern)
	delete(d.uploader)
	delete(d.languages)
	d^ = {}
}

result_node_free :: proc(r: ^Result_Node) {
	picture_release(r.input)
	for &v in r.result.outputs { value_free(&v) }
	delete(r.result.message)
	delete(r.thumbnail)
	delete(r.clipboard_png)
	r^ = {}
}

// Runs the job (on the worker). Its strings and its copy of the node go; the input's reference goes back in the result.
node_work :: proc(j: ^Job_Node, fonts: ^Worker_Fonts) -> (out: Result_Node) {
	out.run, out.node = j.run, j.node
	out.input = j.input.picture
	j.input.picture = nil
	defer job_node_free(j)
	n := &j.n
	shot: Shot
	if out.input != nil { shot = out.input.shot }

	#partial switch n.kind {
	case .Copy_Image:
		// (only the file: the picture's references are the interface's, which sets the clipboard and passes it on)
		out.clipboard_png = png.encode(shot.rgba, shot.size.x, shot.size.y, .Fast)
		if len(out.clipboard_png) == 0 { return node_failed(out, "the picture cannot go to the clipboard") }
		out.result = {ok = true}
	case .Save_File:
		path, size, bytes, err := node_save(n, shot, j.defaults)
		if err != "" { return node_failed(out, err) }
		out.result = {ok = true, made = {0}}
		out.result.outputs[0] = {kind = .File, text = path, size = size, bytes = bytes, origin = .Save_File}
	case .Upload:
		url, problem := node_upload(n, shot, j.defaults)
		if problem != "" { return node_failed(out, problem) }
		out.result = {ok = true, made = {0}}
		out.result.outputs[0] = {kind = .Url, text = url, origin = .Upload}
	case .Read_Qr:
		text, ok := qr_read(shot)
		if !ok { return node_failed(out, FLOW_ERROR_TEXT[.No_Qr]) }
		out.result = {ok = true, made = {0}}
		out.result.outputs[0] = {kind = .Text, text = text, origin = .Read_Qr}
	case .Read_Text:
		langs := node_text(n, "languages")
		if langs == "" { langs = j.defaults.languages }
		text, err := ocr_read(shot, strings.trim_space(langs))
		if err != .None { return node_failed(out, FLOW_ERROR_TEXT[err]) }
		out.result = {ok = true, made = {0}}
		out.result.outputs[0] = {kind = .Text, text = text, origin = .Read_Text}
	case .Show_In_Folder:
		if j.input.text == "" || !platform.reveal_in_folder(j.input.text) { return node_failed(out, "the file cannot be shown in its folder") }
		out.result = {ok = true}
	case:
		if shot.rgba == nil { return node_failed(out, "no picture came in") }
		made, ok := node_transform(n, shot, n.kind == .Watermark ? worker_fonts(fonts) : nil)
		if !ok { return node_failed(out, "the picture could not be made") }
		made.source, made.scale = shot.source, shot.scale
		out.result = {ok = true, made = {0}}
		out.result.outputs[0] = {kind = .Image, picture = picture_make(made), origin = n.kind}
		if j.thumbnail { out.thumbnail, out.thumbnail_size = thumbnail_of(made) }
		return
	}
	// (a node that does not change the picture shows the one it was given)
	if j.thumbnail && shot.rgba != nil { out.thumbnail, out.thumbnail_size = thumbnail_of(shot) }
	return
}

@(private = "file")
node_failed :: proc(out: Result_Node, message: string) -> Result_Node {
	out := out
	out.result = {ok = false, message = strings.clone(message)}
	return out
}

// The picture `shot` (not changed) through the operation of `n`: a new picture (owned). `fonts`: the worker's, for a
// watermark's text (nil: a watermark draws nothing).
node_transform :: proc(n: ^Workflow_Node, shot: Shot, fonts: ^Worker_Fonts = nil) -> (out: Shot, ok: bool) {
	src := pic.Image{pixels = shot.rgba, width = shot.size.x, height = shot.size.y}
	made: pic.Image
	switch n.kind {
	case .Resize:
		w, h := resize_size(n, shot.size)
		if w == shot.size.x && h == shot.size.y { made = pic.clone(src); break }
		filters := [3]pic.Filter{.Lanczos3, .Bilinear, .Box}
		made = pic.resize(src, w, h, filters[node_int(n, "filter")])
	case .Crop:
		l, t, r, b := node_int(n, "left"), node_int(n, "top"), node_int(n, "right"), node_int(n, "bottom")
		w, h := shot.size.x - l - r, shot.size.y - t - b
		if w <= 0 || h <= 0 { return }
		made = pic.crop(src, l, t, w, h)
	case .Rotate:
		turns := [3]int{1, 2, 3}   // (90° right, 180°, 90° left: quarter turns clockwise)
		made = pic.rotate(src, turns[node_int(n, "turn")])
	case .Flip:
		made = pic.flip(src, horizontal = node_int(n, "direction") == 0)
	case .Pad:
		m := node_int(n, "margin")
		made = pic.pad(src, m, m, m, m, node_color(n, "color"))
	case .Border:
		made = pic.border(src, node_int(n, "width"), node_color(n, "color"), inside = node_bool(n, "inside"))
	case .Round_Corners:
		made = pic.round_corners(src, f32(node_int(n, "radius")))
	case .Shadow:
		made = pic.drop_shadow(src, {node_int(n, "x"), node_int(n, "y")}, f32(node_int(n, "blur")), node_color(n, "color"))
	case .Background:
		made = background_make(n, src)
	case .Watermark:
		made = pic.clone(src)
		if text := node_text(n, "text"); text != "" && fonts != nil && fonts.face != 0 {
			anchors := [5]pic.Anchor{.Top_Left, .Top_Right, .Bottom_Left, .Bottom_Right, .Center}
			pic.watermark_text(made, &fonts.state, fonts.face, text, f32(node_int(n, "size")), node_color(n, "color"),
				anchors[node_int(n, "position")], node_int(n, "margin"), f32(node_float(n, "opacity") / 100))
		}
	case .Grayscale:
		made = pic.clone(src)
		pic.grayscale(made)
	case .Invert:
		made = pic.clone(src)
		pic.invert(made)
	case .Brightness_Contrast:
		made = pic.clone(src)
		pic.brightness_contrast(made, f32(node_float(n, "brightness") / 100), f32(node_float(n, "contrast") / 100))
	case .Saturation:
		made = pic.clone(src)
		pic.saturation(made, f32(node_float(n, "amount") / 100))
	case .Hue:
		made = pic.clone(src)
		pic.hue_rotate(made, f32(node_float(n, "degrees")))
	case .Sepia:
		made = pic.clone(src)
		pic.sepia(made)
	case .Threshold:
		made = pic.clone(src)
		pic.threshold(made, u8(node_int(n, "level")))
	case .Blur:
		made = pic.blur(src, f32(node_float(n, "radius")))
	case .Sharpen:
		made = pic.clone(src)
		pic.sharpen(made, f32(node_float(n, "amount") / 100))
	case .Pixelate:
		made = pic.clone(src)
		pic.pixelate(made, node_int(n, "cell"))
	case .Capture, .Annotate, .Condition, .Copy_Image, .Save_File, .Upload, .Copy_Text, .Read_Qr, .Read_Text, .Notify, .Show_In_Folder, .Add_To_History:
		return
	}
	if made.pixels == nil || made.width <= 0 || made.height <= 0 { return }
	return {rgba = made.pixels, size = {made.width, made.height}}, true
}

// The size a Resize gives a picture of `size`: by a percentage, or within a largest width and height (never larger).
resize_size :: proc(n: ^Workflow_Node, size: [2]int) -> (w, h: int) {
	if Resize_Mode(node_int(n, "mode")) == .Percent {
		k := node_float(n, "percent") / 100
		return max(int(math.round(f64(size.x) * k)), 1), max(int(math.round(f64(size.y) * k)), 1)
	}
	k := 1.0
	if mw := node_int(n, "width"); mw > 0 && size.x > mw { k = min(k, f64(mw) / f64(size.x)) }
	if mh := node_int(n, "height"); mh > 0 && size.y > mh { k = min(k, f64(mh) / f64(size.y)) }
	return max(int(math.round(f64(size.x) * k)), 1), max(int(math.round(f64(size.y) * k)), 1)
}

// The "beautified screenshot": the picture's corners rounded, a shadow under it, on a margin of colour or gradient.
@(private = "file")
background_make :: proc(n: ^Workflow_Node, src: pic.Image) -> pic.Image {
	current := src
	owned := false
	if r := node_int(n, "radius"); r > 0 {
		current = pic.round_corners(current, f32(r))
		owned = true
	}
	if node_bool(n, "shadow") {
		shadowed := pic.drop_shadow(current, {0, 12}, 28, {0, 0, 0, 120})
		if owned { pic.destroy(&current) }
		current, owned = shadowed, true
	}
	// (a flat fill is a gradient from a colour to itself)
	fill := pic.solid(node_color(n, "color"))
	if node_int(n, "fill") == 1 { fill = {from = node_color(n, "color"), to = node_color(n, "color2"), angle = f32(node_float(n, "angle"))} }
	out := pic.background(current, node_int(n, "margin"), fill)
	if owned { pic.destroy(&current) }
	return out
}

// The picture saved as the node says: its folder (empty: the default one), its name pattern (empty: the default one),
// PNG small or fast. path: owned; err "" when saved.
@(private = "file")
node_save :: proc(n: ^Workflow_Node, shot: Shot, d: Node_Defaults) -> (path: string, size: [2]int, bytes: i64, err: string) {
	if shot.rgba == nil { return "", {}, 0, "no picture came in" }
	format := Save_Format(clamp(node_int(n, "format"), 0, len(Save_Format) - 1))
	quality := clamp(node_int(n, "quality"), 1, 100)
	img := pic.Image{pixels = shot.rgba, width = shot.size.x, height = shot.size.y}
	file: []u8
	switch format {
	case .Png_Small:     file = png.encode(shot.rgba, shot.size.x, shot.size.y, .Small)
	case .Png_Fast:      file = png.encode(shot.rgba, shot.size.x, shot.size.y, .Fast)
	case .Jpeg:          file = pic.jpeg_encode(img, quality)
	case .Webp, .Webp_Lossless:
		if !pic.webp_available() { return "", {}, 0, "this system has no WebP encoder (install libwebp)" }
		file = pic.webp_encode(img, quality, format == .Webp_Lossless)
	}
	defer delete(file)
	if file == nil { return "", {}, 0, FLOW_ERROR_TEXT[.Empty] }
	pattern := node_text(n, "name")
	if pattern == "" { pattern = d.pattern }
	if pattern == "" { pattern = DEFAULT_NAME_PATTERN }
	folder := node_text(n, "folder")
	if folder == "" { folder = d.folder }
	name := name_with_extension(name_expand(pattern, stamp_now(), shot.source, context.temp_allocator), SAVE_FORMAT_EXTENSION[format])
	p, e := save_file(file, folder, name)
	if e != .None { return "", {}, 0, FLOW_ERROR_TEXT[e] }
	return p, shot.size, i64(len(file)), ""
}

// The picture sent to the node's host (empty: the default one). url: owned.
@(private = "file")
node_upload :: proc(n: ^Workflow_Node, shot: Shot, d: Node_Defaults) -> (url: string, problem: string) {
	if shot.rgba == nil { return "", "no picture came in" }
	file := png.encode(shot.rgba, shot.size.x, shot.size.y, .Fast)
	defer delete(file)
	if file == nil { return "", FLOW_ERROR_TEXT[.Empty] }
	list, _ := uploaders_load(context.temp_allocator)
	name := node_text(n, "uploader")
	if name == "" { name = d.uploader }
	u, _ := uploader_find(list, name)
	if u == nil { return "", "no uploader is set up" }
	file_name := name_expand(d.pattern != "" ? d.pattern : DEFAULT_NAME_PATTERN, stamp_now(), shot.source, context.temp_allocator)
	url, problem = upload_shot(u^, file, file_name)
	if problem != "" {
		delete(url)
		p := strings.clone(problem, context.temp_allocator)
		delete(problem)
		return "", p
	}
	return url, ""
}

// A small copy of `shot` (its largest side THUMBNAIL_SIDE) for the node in the Workflows mode. Owned.
thumbnail_of :: proc(shot: Shot) -> (rgba: []u8, size: [2]int) {
	if shot.rgba == nil || shot.size.x <= 0 || shot.size.y <= 0 { return }
	k := min(f64(THUMBNAIL_SIDE) / f64(shot.size.x), f64(THUMBNAIL_SIDE) / f64(shot.size.y), 1)
	w, h := max(int(f64(shot.size.x) * k), 1), max(int(f64(shot.size.y) * k), 1)
	src := pic.Image{pixels = shot.rgba, width = shot.size.x, height = shot.size.y}
	// (Box: the fastest downscale, enough for a picture this small)
	out := pic.resize(src, w, h, .Box)
	return out.pixels, {out.width, out.height}
}

// A PNG file of the history decoded (on the worker), for a preview run of `workflow`.
picture_load :: proc(path: string, workflow: u64) -> Result_Picture {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return {workflow = workflow} }
	defer delete(data)
	rgba, w, h, ok := png.decode(data)
	if !ok { return {workflow = workflow} }
	return {shot = {rgba = rgba, size = {w, h}, source = .Region, scale = 1}, workflow = workflow, ok = true}
}

// A font for the text a watermark draws, on the worker's thread (a font.State is one thread's): made at the first
// watermark, the system's interface font else the toolkit's own.
Worker_Fonts :: struct {
	state: font.State,
	face:  font.Font_Id,
	made:  bool,
}

worker_fonts :: proc(f: ^Worker_Fonts) -> ^Worker_Fonts {
	if f.made { return f }
	f.made = true
	font.init(&f.state)
	f.face, _, _ = font.load_system_or_embedded(&f.state, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	return f
}

worker_fonts_destroy :: proc(f: ^Worker_Fonts) {
	if f.made { font.destroy(&f.state) }
	f^ = {}
}
