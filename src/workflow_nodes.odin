package cliche

// The catalog of node kinds, as gt:flowgraph's data (docs/flowgraph.md of the toolkit): for each, its icon, its title,
// its group, its ports and its parameters. The edits, the file, the run, the inspector (ui.node_inspector) and the add
// palette (ui.flow_palette) read it, with no code per kind. node_summary gives a node's subtitle; workflow_ops.odin does
// each kind's work, workflow_app.odin the interface's part.

import "core:fmt"
import "core:strings"
import flowgraph "gt:flowgraph"
import lucide "gt:lucide"

// The node kinds, in the order of CATALOG.nodes: flowgraph.Node.kind is `int(Node_Kind)`.
Node_Kind :: enum u8 {
	Capture,
	// geometry
	Resize, Crop, Rotate, Flip, Pad,
	// look
	Border, Round_Corners, Shadow, Background, Watermark,
	// colour
	Grayscale, Invert, Brightness_Contrast, Saturation, Hue, Sepia, Threshold,
	// filters
	Blur, Sharpen, Pixelate,
	// interactive and flow control
	Annotate, Condition,
	// outputs
	Copy_Image, Save_File, Upload, Copy_Text, Read_Qr, Read_Text, Notify, Show_In_Folder, Add_To_History,
}

// What flows on a link (flowgraph.Port_Kind: CATALOG.kinds[k]; 0 is the engine's ACTION). A text takes an address or a
// file's path; Any takes every kind but an action (Notify, Add to history).
PORT_IMAGE :: flowgraph.Port_Kind(1)
PORT_TEXT  :: flowgraph.Port_Kind(2)
PORT_URL   :: flowgraph.Port_Kind(3)
PORT_FILE  :: flowgraph.Port_Kind(4)
PORT_ANY   :: flowgraph.Port_Kind(5)

// Where a node's work runs (flowgraph.Node_Def.place): the worker (pixels, disk, network), the interface's thread (the
// clipboard, a notification, the history), the editor (a person), or the run itself, at once (Capture, Condition).
Node_Place :: enum u8 { Worker, Interface, Editor, Run }

@(private = "file") PLACE_WORKER    :: u8(Node_Place.Worker)
@(private = "file") PLACE_INTERFACE :: u8(Node_Place.Interface)
@(private = "file") PLACE_EDITOR    :: u8(Node_Place.Editor)
@(private = "file") PLACE_RUN       :: u8(Node_Place.Run)

@(private = "file") BLACK :: [4]u8{0, 0, 0, 255}
@(private = "file") WHITE :: [4]u8{255, 255, 255, 255}

Resize_Mode :: enum u8 { Percent, Largest }
Condition_Test :: enum u8 { Width, Height, Aspect, Source }
Condition_Compare :: enum u8 { More, Less, Equal }
Notify_Show :: enum u8 { Input, Summary }
Save_Format :: enum u8 { Png_Small, Png_Fast, Jpeg, Webp, Webp_Lossless }

SAVE_FORMAT_TEXT := [Save_Format]string{.Png_Small = "PNG", .Png_Fast = "PNG (fast)", .Jpeg = "JPEG", .Webp = "WebP", .Webp_Lossless = "WebP (lossless)"}
// The extension a file of each format gets, in place of the one its name pattern ends with (".png" by default).
SAVE_FORMAT_EXTENSION := [Save_Format]string{.Png_Small = ".png", .Png_Fast = ".png", .Jpeg = ".jpg", .Webp = ".webp", .Webp_Lossless = ".webp"}

// The effects (the clipboard, a file, the network, a notification, the history) have an action input, "when": linked to
// an Annotate's "done", the effect waits for the person's Done; linked to its "cancelled", it runs only when they gave
// up. Left unlinked, it asks for nothing.
CATALOG := flowgraph.Catalog{
	kinds = {
		{name = "action"},
		{name = "picture", transient = true},   // (let go as soon as no node waits for it: pictures are large)
		{name = "text", accepts = {PORT_URL, PORT_FILE}},
		{name = "address"},
		{name = "file"},
		{name = "anything", any = true},
	},
	nodes = {
		{name = "capture", title = "Capture", group = "Source", icon = lucide.MONITOR, tags = {"start", "trigger", "screenshot"}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_RUN, max_count = 1, min_count = 1},

		{name = "resize", title = "Resize", group = "Geometry", icon = lucide.ZOOM_OUT, tags = {"scale", "smaller", "size", "shrink"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "mode", title = "By", type = .Choice, choices = {"Percent", "Largest size"}},
			{name = "percent", title = "Scale", type = .Float, lo = 1, hi = 400, step = 1, unit = "%", default_number = 50},
			{name = "width", title = "Largest width", type = .Int, lo = 0, hi = 16384, step = 1, unit = "px", default_number = 1920},
			{name = "height", title = "Largest height", type = .Int, lo = 0, hi = 16384, step = 1, unit = "px", default_number = 1080},
			{name = "filter", title = "Filter", type = .Choice, choices = {"Sharp", "Smooth", "Fast"}},
		}},
		{name = "crop", title = "Crop", group = "Geometry", icon = lucide.SCISSORS, tags = {"cut", "trim", "margins"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "left", title = "Left", type = .Int, lo = 0, hi = 4096, step = 1, unit = "px"},
			{name = "top", title = "Top", type = .Int, lo = 0, hi = 4096, step = 1, unit = "px"},
			{name = "right", title = "Right", type = .Int, lo = 0, hi = 4096, step = 1, unit = "px"},
			{name = "bottom", title = "Bottom", type = .Int, lo = 0, hi = 4096, step = 1, unit = "px"},
		}},
		{name = "rotate", title = "Rotate", group = "Geometry", icon = lucide.ROTATE_CCW, tags = {"turn", "quarter", "orientation"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "turn", title = "Turn", type = .Choice, choices = {"90° right", "180°", "90° left"}},
		}},
		{name = "flip", title = "Flip", group = "Geometry", icon = lucide.ARROW_UP_DOWN, tags = {"mirror", "reverse"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "direction", title = "Direction", type = .Choice, choices = {"Left to right", "Top to bottom"}},
		}},
		{name = "pad", title = "Pad", group = "Geometry", icon = lucide.SQUARE, tags = {"margin", "space", "frame", "padding"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "margin", title = "Margin", type = .Int, lo = 0, hi = 1024, step = 1, unit = "px", default_number = 32},
			{name = "color", title = "Colour", type = .Color, default_color = {0, 0, 0, 0}},
		}},

		{name = "border", title = "Border", group = "Look", icon = lucide.SQUARE, tags = {"outline", "frame", "stroke"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "width", title = "Width", type = .Int, lo = 1, hi = 256, step = 1, unit = "px", default_number = 4},
			{name = "color", title = "Colour", type = .Color, default_color = BLACK},
			{name = "inside", title = "Inside the picture", type = .Bool},
		}},
		{name = "round_corners", title = "Rounded corners", group = "Look", icon = lucide.APP_WINDOW, tags = {"radius", "round", "corner"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "radius", title = "Radius", type = .Int, lo = 1, hi = 512, step = 1, unit = "px", default_number = 12},
		}},
		{name = "shadow", title = "Drop shadow", group = "Look", icon = lucide.LAYERS_2, tags = {"shadow", "depth", "glow"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "blur", title = "Blur", type = .Int, lo = 0, hi = 256, step = 1, unit = "px", default_number = 24},
			{name = "x", title = "Offset right", type = .Int, lo = -256, hi = 256, step = 1, unit = "px", default_number = 0},
			{name = "y", title = "Offset down", type = .Int, lo = -256, hi = 256, step = 1, unit = "px", default_number = 8},
			{name = "color", title = "Colour", type = .Color, default_color = {0, 0, 0, 140}},
		}},
		{name = "background", title = "Background", group = "Look", icon = lucide.PALETTE, tags = {"beautify", "gradient", "backdrop", "wallpaper", "pretty"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "margin", title = "Margin", type = .Int, lo = 0, hi = 1024, step = 1, unit = "px", default_number = 64},
			{name = "fill", title = "Fill", type = .Choice, choices = {"Colour", "Gradient"}, default_number = 1},
			{name = "color", title = "Colour", type = .Color, default_color = {99, 102, 241, 255}},
			{name = "color2", title = "Second colour", type = .Color, default_color = {236, 72, 153, 255}},
			{name = "angle", title = "Angle", type = .Float, lo = 0, hi = 360, step = 1, unit = "°", default_number = 135},
			{name = "radius", title = "Picture's corners", type = .Int, lo = 0, hi = 256, step = 1, unit = "px", default_number = 12},
			{name = "shadow", title = "Shadow under the picture", type = .Bool, default_number = 1},
		}},
		{name = "watermark", title = "Watermark", group = "Look", icon = lucide.TYPE, tags = {"text", "signature", "copyright", "label"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "text", title = "Text", type = .Text, default_text = "cliche"},
			{name = "position", title = "Position", type = .Choice, choices = {"Top left", "Top right", "Bottom left", "Bottom right", "Centre"}, default_number = 3},
			{name = "size", title = "Size", type = .Int, lo = 6, hi = 256, step = 1, unit = "px", default_number = 24},
			{name = "color", title = "Colour", type = .Color, default_color = WHITE},
			{name = "opacity", title = "Opacity", type = .Float, lo = 0, hi = 100, step = 1, unit = "%", default_number = 60},
			{name = "margin", title = "Margin", type = .Int, lo = 0, hi = 512, step = 1, unit = "px", default_number = 16},
		}},

		{name = "grayscale", title = "Grayscale", group = "Colour", icon = lucide.SUN_MOON, tags = {"black and white", "grey", "gray", "monochrome"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER},
		{name = "invert", title = "Invert", group = "Colour", icon = lucide.SUN_MOON, tags = {"negative", "reverse"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER},
		{name = "brightness_contrast", title = "Brightness and contrast", group = "Colour", icon = lucide.LIGHTBULB, tags = {"light", "dark", "exposure"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "brightness", title = "Brightness", type = .Float, lo = -100, hi = 100, step = 1, unit = "%"},
			{name = "contrast", title = "Contrast", type = .Float, lo = -100, hi = 100, step = 1, unit = "%"},
		}},
		{name = "saturation", title = "Saturation", group = "Colour", icon = lucide.PALETTE, tags = {"vivid", "colourful", "desaturate"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "amount", title = "Amount", type = .Float, lo = 0, hi = 300, step = 1, unit = "%", default_number = 130},
		}},
		{name = "hue", title = "Hue", group = "Colour", icon = lucide.PALETTE, tags = {"tint", "shift", "rotate"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "degrees", title = "Turn", type = .Float, lo = -180, hi = 180, step = 1, unit = "°", default_number = 30},
		}},
		{name = "sepia", title = "Sepia", group = "Colour", icon = lucide.FILM, tags = {"old", "vintage", "brown"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER},
		{name = "threshold", title = "Threshold", group = "Colour", icon = lucide.GAUGE, tags = {"black", "white", "binary", "scan"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "level", title = "Level", type = .Int, lo = 0, hi = 255, step = 1, default_number = 128},
		}},

		{name = "blur", title = "Blur", group = "Filters", icon = lucide.EYE_OFF, tags = {"soft", "gaussian", "hide"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "radius", title = "Radius", type = .Float, lo = 0.5, hi = 64, step = 0.5, unit = "px", default_number = 4},
		}},
		{name = "sharpen", title = "Sharpen", group = "Filters", icon = lucide.ZAP, tags = {"crisp", "detail", "unsharp"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "amount", title = "Amount", type = .Float, lo = 0, hi = 300, step = 1, unit = "%", default_number = 50},
		}},
		{name = "pixelate", title = "Pixelate", group = "Filters", icon = lucide.LAYOUT_GRID, tags = {"mosaic", "censor", "redact", "blocks"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, params = {
			{name = "cell", title = "Cell", type = .Int, lo = 2, hi = 256, step = 1, unit = "px", default_number = 12},
		}},

		{name = "annotate", title = "Annotate", group = "Interactive", icon = lucide.PENCIL, tags = {"editor", "draw", "arrow", "markup", "edit", "done", "cancel"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {
			{name = "picture", kind = PORT_IMAGE},
			{name = "done", kind = flowgraph.ACTION, on = .Done},
			{name = "cancelled", kind = flowgraph.ACTION, on = .Cancelled},
		}, place = PLACE_EDITOR},
		{name = "condition", title = "Condition", group = "Flow control", icon = lucide.GIT_FORK, tags = {"if", "branch", "test", "when"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "yes", kind = PORT_IMAGE}, {name = "no", kind = PORT_IMAGE}}, place = PLACE_RUN, params = {
			{name = "test", title = "When", type = .Choice, choices = {"Width", "Height", "Width / height", "Source"}},
			{name = "compare", title = "Is", type = .Choice, choices = {"More than", "Less than", "Equal to"}},
			{name = "value", title = "Value", type = .Float, lo = 0, hi = 16384, step = 1, default_number = 1920},
			{name = "source", title = "Source", type = .Choice, choices = {"Region", "Screen", "Window"}},
		}},

		{name = "copy_image", title = "Copy image", group = "Outputs", icon = lucide.COPY, tags = {"clipboard", "paste"}, inputs = {{name = "picture", kind = PORT_IMAGE}, {name = "when", kind = flowgraph.ACTION}}, outputs = {{name = "picture", kind = PORT_IMAGE}}, place = PLACE_WORKER, effect = true},   // (the worker encodes its PNG; the interface sets the clipboard: workflow_node_result)
		{name = "save_file", title = "Save file", group = "Outputs", icon = lucide.SAVE, tags = {"disk", "png", "write", "folder"}, inputs = {{name = "picture", kind = PORT_IMAGE}, {name = "when", kind = flowgraph.ACTION}}, outputs = {{name = "file", kind = PORT_FILE}}, place = PLACE_WORKER, effect = true, params = {
			{name = "folder", title = "Folder", type = .Folder, placeholder = "The default folder (Settings, Save)"},
			{name = "name", title = "File name", type = .Text, placeholder = "The default name (Settings, Save)"},
			{name = "format", title = "Format", type = .Choice, choices = {"PNG, small", "PNG, fast", "JPEG", "WebP", "WebP, lossless"}},
			{name = "quality", title = "Quality", type = .Int, lo = 1, hi = 100, step = 1, unit = "%", default_number = 90},   // (JPEG and WebP)
		}},
		{name = "upload", title = "Upload", group = "Outputs", icon = lucide.SEND_HORIZONAL, tags = {"share", "host", "link", "sxcu", "imgur"}, inputs = {{name = "picture", kind = PORT_IMAGE}, {name = "when", kind = flowgraph.ACTION}}, outputs = {{name = "address", kind = PORT_URL}}, place = PLACE_WORKER, effect = true, params = {
			{name = "uploader", title = "Host", type = .List},
		}},
		{name = "copy_text", title = "Copy text", group = "Outputs", icon = lucide.CLIPBOARD_COPY, tags = {"clipboard", "url", "address", "link"}, inputs = {{name = "text", kind = PORT_TEXT}, {name = "when", kind = flowgraph.ACTION}}, outputs = {{name = "text", kind = PORT_TEXT}}, place = PLACE_INTERFACE, effect = true},
		{name = "read_qr", title = "Read QR code", group = "Outputs", icon = lucide.QR_CODE, tags = {"scan", "barcode", "decode"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "text", kind = PORT_TEXT}}, place = PLACE_WORKER},
		{name = "read_text", title = "Read text", group = "Outputs", icon = lucide.TEXT_CURSOR_INPUT, tags = {"ocr", "recognition", "tesseract"}, inputs = {{name = "picture", kind = PORT_IMAGE}}, outputs = {{name = "text", kind = PORT_TEXT}}, place = PLACE_WORKER, params = {
			{name = "languages", title = "Languages", type = .Text, placeholder = "The default languages (Settings, Capture)"},
		}},
		{name = "notify", title = "Notify", group = "Outputs", icon = lucide.BELL, tags = {"notification", "toast", "message", "tell"}, inputs = {{name = "what", kind = PORT_ANY, multiple = true}, {name = "when", kind = flowgraph.ACTION}}, place = PLACE_INTERFACE, effect = true, params = {
			{name = "title", title = "Title", type = .Text, placeholder = "Said for you: \"Screenshot saved\""},
			{name = "show", title = "Show", type = .Choice, choices = {"What comes in", "A summary of the run"}},
		}},
		{name = "show_in_folder", title = "Show in folder", group = "Outputs", icon = lucide.FOLDER_OPEN, tags = {"reveal", "explorer", "file manager"}, inputs = {{name = "file", kind = PORT_FILE}, {name = "when", kind = flowgraph.ACTION}}, place = PLACE_WORKER, effect = true},
		{name = "add_to_history", title = "Add to history", group = "Outputs", icon = lucide.HISTORY, tags = {"remember", "keep", "list"}, inputs = {{name = "what", kind = PORT_ANY, multiple = true}, {name = "when", kind = flowgraph.ACTION}}, place = PLACE_INTERFACE, effect = true},
	},
}

// A line under the node's title that says what it does with its parameters ("50 %", "PNG to ~/Pictures"). Temp
// allocator; "" when there is nothing to say.
node_summary :: proc(n: ^flowgraph.Node) -> string {
	switch Node_Kind(n.kind) {
	case .Capture, .Grayscale, .Invert, .Sepia, .Annotate, .Copy_Image, .Copy_Text, .Read_Qr, .Show_In_Folder, .Add_To_History:
		return ""
	case .Resize:
		if Resize_Mode(flowgraph.param_int(&CATALOG, n, "mode")) == .Percent { return fmt.tprintf("%s %%", number_text(flowgraph.param_float(&CATALOG, n, "percent"))) }
		w, h := flowgraph.param_int(&CATALOG, n, "width"), flowgraph.param_int(&CATALOG, n, "height")
		switch {
		case w > 0 && h > 0: return fmt.tprintf("at most %d × %d px", w, h)
		case w > 0:          return fmt.tprintf("at most %d px wide", w)
		case h > 0:          return fmt.tprintf("at most %d px high", h)
		}
		return "no change"
	case .Crop:
		l, t, r, b := flowgraph.param_int(&CATALOG, n, "left"), flowgraph.param_int(&CATALOG, n, "top"), flowgraph.param_int(&CATALOG, n, "right"), flowgraph.param_int(&CATALOG, n, "bottom")
		if l == t && t == r && r == b { return fmt.tprintf("%d px each side", l) }
		return fmt.tprintf("%d, %d, %d, %d px", l, t, r, b)
	case .Rotate, .Flip:
		return flowgraph.param_choice_text(&CATALOG, n, Node_Kind(n.kind) == .Rotate ? "turn" : "direction")
	case .Pad:
		return fmt.tprintf("%d px, %s", flowgraph.param_int(&CATALOG, n, "margin"), color_text(flowgraph.param_color(&CATALOG, n, "color")))
	case .Border:
		return fmt.tprintf("%d px %s%s", flowgraph.param_int(&CATALOG, n, "width"), color_text(flowgraph.param_color(&CATALOG, n, "color")), flowgraph.param_bool(&CATALOG, n, "inside") ? ", inside" : "")
	case .Round_Corners:
		return fmt.tprintf("%d px", flowgraph.param_int(&CATALOG, n, "radius"))
	case .Shadow:
		return fmt.tprintf("blur %d px, %+d %+d", flowgraph.param_int(&CATALOG, n, "blur"), flowgraph.param_int(&CATALOG, n, "x"), flowgraph.param_int(&CATALOG, n, "y"))
	case .Background:
		if flowgraph.param_int(&CATALOG, n, "fill") == 1 {
			return fmt.tprintf("%d px, %s to %s", flowgraph.param_int(&CATALOG, n, "margin"), color_text(flowgraph.param_color(&CATALOG, n, "color")), color_text(flowgraph.param_color(&CATALOG, n, "color2")))
		}
		return fmt.tprintf("%d px, %s", flowgraph.param_int(&CATALOG, n, "margin"), color_text(flowgraph.param_color(&CATALOG, n, "color")))
	case .Watermark:
		text := flowgraph.param_text(&CATALOG, n, "text")
		if text == "" { return "no text" }
		return fmt.tprintf("\"%s\", %s", text_cut(text, 18), strings.to_lower(flowgraph.param_choice_text(&CATALOG, n, "position"), context.temp_allocator))
	case .Brightness_Contrast:
		return fmt.tprintf("%+d %%, contrast %+d %%", int(flowgraph.param_float(&CATALOG, n, "brightness")), int(flowgraph.param_float(&CATALOG, n, "contrast")))
	case .Saturation:
		return fmt.tprintf("%s %%", number_text(flowgraph.param_float(&CATALOG, n, "amount")))
	case .Hue:
		return fmt.tprintf("%+d°", int(flowgraph.param_float(&CATALOG, n, "degrees")))
	case .Threshold:
		return fmt.tprintf("level %d", flowgraph.param_int(&CATALOG, n, "level"))
	case .Blur:
		return fmt.tprintf("%s px", number_text(flowgraph.param_float(&CATALOG, n, "radius")))
	case .Sharpen:
		return fmt.tprintf("%s %%", number_text(flowgraph.param_float(&CATALOG, n, "amount")))
	case .Pixelate:
		return fmt.tprintf("cells of %d px", flowgraph.param_int(&CATALOG, n, "cell"))
	case .Condition:
		test := Condition_Test(flowgraph.param_int(&CATALOG, n, "test"))
		if test == .Source { return fmt.tprintf("the source is a %s", strings.to_lower(flowgraph.param_choice_text(&CATALOG, n, "source"), context.temp_allocator)) }
		what := [Condition_Test]string{.Width = "width", .Height = "height", .Aspect = "width / height", .Source = ""}
		op := [Condition_Compare]string{.More = ">", .Less = "<", .Equal = "="}
		return fmt.tprintf("%s %s %s", what[test], op[Condition_Compare(flowgraph.param_int(&CATALOG, n, "compare"))], number_text(flowgraph.param_float(&CATALOG, n, "value")))
	case .Save_File:
		f := Save_Format(clamp(flowgraph.param_int(&CATALOG, n, "format"), 0, len(Save_Format) - 1))
		format := SAVE_FORMAT_TEXT[f]
		if f == .Jpeg || f == .Webp { format = fmt.tprintf("%s %d %%", format, flowgraph.param_int(&CATALOG, n, "quality")) }
		folder := flowgraph.param_text(&CATALOG, n, "folder")
		if folder == "" { return fmt.tprintf("%s to the default folder", format) }
		return fmt.tprintf("%s to %s", format, path_short(folder))
	case .Upload:
		u := flowgraph.param_text(&CATALOG, n, "uploader")
		return u != "" ? fmt.tprintf("to %s", u) : "to the default host"
	case .Read_Text:
		langs := flowgraph.param_text(&CATALOG, n, "languages")
		return langs != "" ? langs : ""
	case .Notify:
		t := flowgraph.param_text(&CATALOG, n, "title")
		show := Notify_Show(flowgraph.param_int(&CATALOG, n, "show")) == .Summary ? "a summary" : "what comes in"
		return t != "" ? fmt.tprintf("\"%s\": %s", text_cut(t, 16), show) : show
	}
	return ""
}

// A number with no ".0" when it is whole.
@(private = "file")
number_text :: proc(v: f64) -> string {
	if v == f64(i64(v)) { return fmt.tprintf("%d", i64(v)) }
	return fmt.tprintf("%.1f", v)
}

// "#rrggbb", with its alpha when not opaque.
color_text :: proc(c: [4]u8) -> string {
	if c.a == 255 { return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b) }
	if c.a == 0 { return "transparent" }
	return fmt.tprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
}

// The text cut at about `most` characters, with an ellipsis.
@(private = "file")
text_cut :: proc(s: string, most: int) -> string {
	n := 0
	for _, i in s {
		if n == most { return fmt.tprintf("%s…", s[:i]) }
		n += 1
	}
	return s
}

// The last two parts of a path: enough to know it, short enough for a subtitle.
@(private = "file")
path_short :: proc(path: string) -> string {
	p := strings.trim_right(path, "/\\")
	cut := strings.last_index_any(p, "/\\")
	if cut <= 0 { return p }
	before := strings.last_index_any(p[:cut], "/\\")
	if before <= 0 { return p }
	return fmt.tprintf("…%s", p[before:])
}
