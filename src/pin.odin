package cliche

// Pinned pictures: a picture kept over every other window, to read from while working elsewhere. Each pin is a window of
// its own (app.pins), any number together, opened from the editor (Ctrl+T, its bar) or from a file (pin_picture: the
// history's action).
//
// The window is the toolkit's overlay (host.Open.overlay): a layer surface of the overlay layer on Wayland, an
// override-redirect window on X11, a topmost tool window on Windows. It covers the output and is transparent but for
// the picture, the only part that takes the pointer (platform.set_input_region): the windows below stay usable around
// it. A drag moves the picture (within its output), the wheel zooms it around the pointer, a double click or Escape
// closes it (the keyboard is the pin's once it is clicked), a right click opens its menu (copy, save, close).
//
// Where the compositor has no layer shell (GNOME), no client window can ask to stay on top: the pin is then a normal
// window of the picture's size (said once), moved by its title bar, its wheel resizing it.
//
// The pointer's gesture is one state machine (Pin_Gesture: Still -> Dragging -> Still); the geometry is pure
// (pin_place_first, pin_zoom_at, pin_drag_to, pin_input_rect) and tested without a window.

import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "gt:draw"
import "gt:font"
import "gt:host"
import i18n "gt:i18n"
import pic "gt:image"
import lucide "gt:lucide"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import tasks "gt:tasks"
import "gt:ui"

PIN_ZOOM_MIN  :: 0.1
PIN_ZOOM_MAX  :: 8.0
PIN_ZOOM_STEP :: 1.1    // a notch of the wheel
PIN_FIRST_MOST :: 0.8   // of the output, at most, when a pin first shows
PIN_KEEP_PX   :: 32     // of the picture always on its output: it can always be taken back
PIN_DOUBLE_CLICK_MS :: 450
PIN_DOUBLE_CLICK_PX :: 5
// A normal window's size, in logical pixels (where no window stays on top): never smaller, nor larger at first.
PIN_WINDOW_LEAST :: [2]f32{64, 64}
PIN_WINDOW_FIRST_MOST :: [2]f32{1600, 1000}

@(private = "file") PIN_MENU :: "pin_menu"

// Where the picture is in its window, in logical pixels: its top left, and its zoom (1: as large as on the screen it
// was taken on).
Pin_Place :: struct {
	at:   [2]f32,
	zoom: f32,
}

// The pointer's gesture on a pin.
Pin_Still    :: struct {}
Pin_Dragging :: struct { grab: [2]f32 }   // where the pointer holds the picture, from its top left
Pin_Gesture  :: union #no_nil { Pin_Still, Pin_Dragging }

// The heap's (app.pins holds the pointers): its host must stay where it is while the window is open.
Pin :: struct {
	app:         ^App,
	host:        host.Host,
	on_top:      bool,       // an overlay: over every window; false: a normal window
	visible:     bool,
	closed:      bool,       // pins_sweep frees it
	close_due:   bool,       // asked in a frame: acted on after it
	shot:        Shot,       // the picture (owned)
	tex:         render.Texture,
	place:       Pin_Place,
	placed:      bool,       // the first build placed it (the window's size is known then)
	gesture:     Pin_Gesture,
	window:      [2]f32,     // the window's logical size at the last build
	menu_due:    bool,
	menu_at:     [2]f32,
	menu_open:   bool,       // at the last build: the whole window takes the pointer meanwhile
	input_set:   [4]int,     // the input region given last (all zero: none yet)
	input_whole: bool,
	last_press:  time.Tick,
	last_press_at: [2]f32,
	icons:       font.Font_Id,
	theme_shown: ui.Theme_Shown,
}

// A file of the history read and decoded by a task of the chores for a pin (pin_picture). Who frees it is whoever
// comes last, as for Editor_Load_Work.
Pin_Load :: struct {
	path:  string,   // owned
	shot:  Shot,     // owned once read
	ok:    bool,
	state: Load_State,   // atomic
	app:   ^App,
}

////////////////////////////////
// The geometry (pure)

// The picture's size in its window at `zoom`, logical pixels.
pin_size :: proc(picture: [2]int, scale: f32, zoom: f32) -> [2]f32 {
	s := scale > 0 ? scale : 1
	return {f32(picture.x) / s * zoom, f32(picture.y) / s * zoom}
}

// Where a pin first shows: as large as on its screen, smaller when that is more than PIN_FIRST_MOST of the window,
// centred, on whole pixels.
pin_place_first :: proc(picture: [2]int, scale: f32, window: [2]f32) -> Pin_Place {
	natural := pin_size(picture, scale, 1)
	zoom := f32(1)
	if natural.x > 0 && natural.y > 0 {
		zoom = min(1, PIN_FIRST_MOST * window.x / natural.x, PIN_FIRST_MOST * window.y / natural.y)
	}
	zoom = clamp(zoom, PIN_ZOOM_MIN, PIN_ZOOM_MAX)
	size := pin_size(picture, scale, zoom)
	return {at = {math.round((window.x - size.x) / 2), math.round((window.y - size.y) / 2)}, zoom = zoom}
}

// `p` zoomed by `notches` of the wheel (up: larger) around `pointer`: the point of the picture under it stays there.
pin_zoom_at :: proc(p: Pin_Place, pointer: [2]f32, notches: f32) -> Pin_Place {
	zoom := clamp(p.zoom * math.pow(PIN_ZOOM_STEP, notches), PIN_ZOOM_MIN, PIN_ZOOM_MAX)
	k := zoom / p.zoom
	return {at = pointer - (pointer - p.at) * k, zoom = zoom}
}

// `p` dragged: the point held (`grab`, from the picture's top left) under `pointer`, PIN_KEEP_PX of the picture kept in
// the window on each axis.
pin_drag_to :: proc(p: Pin_Place, picture: [2]int, scale: f32, pointer, grab, window: [2]f32) -> Pin_Place {
	size := pin_size(picture, scale, p.zoom)
	at := pointer - grab
	keep := [2]f32{min(PIN_KEEP_PX, size.x), min(PIN_KEEP_PX, size.y)}
	at.x = clamp(at.x, keep.x - size.x, window.x - keep.x)
	at.y = clamp(at.y, keep.y - size.y, window.y - keep.y)
	return {at = at, zoom = p.zoom}
}

// The picture's rect in its window, whole logical pixels around it (x, y, width, height): the input region.
pin_input_rect :: proc(p: Pin_Place, picture: [2]int, scale: f32) -> [4]int {
	size := pin_size(picture, scale, p.zoom)
	x0, y0 := int(math.floor(p.at.x)), int(math.floor(p.at.y))
	x1, y1 := int(math.ceil(p.at.x + size.x)), int(math.ceil(p.at.y + size.y))
	return {x0, y0, max(x1 - x0, 1), max(y1 - y0, 1)}
}

// Whether `at` is on the picture.
@(private = "file")
pin_hit :: proc(p: ^Pin, at: [2]f32) -> bool {
	size := pin_size(p.shot.size, p.shot.scale, p.place.zoom)
	return at.x >= p.place.at.x && at.y >= p.place.at.y && at.x < p.place.at.x + size.x && at.y < p.place.at.y + size.y
}

////////////////////////////////
// Opening and closing

// `shot` (taken: the pin owns it) pinned over the other windows, on the output the system chooses (the one in use).
pin_open :: proc(app: ^App, shot: Shot) {
	shot := shot
	// (a pin is never the renderer's own window: that one could not close while the others need it; an editor or the
	// main window is always there before)
	if shot.rgba == nil || shot.size.x <= 0 || shot.size.y <= 0 || app.shared.main == nil { shot_free(&shot); return }
	if shot.scale <= 0 { shot.scale = 1 }
	p := new(Pin)
	p^ = {app = app, shot = shot}
	p.on_top = host.host_open(&p.host, &app.shared, {title = "cliche pin", overlay = true}, pin_build, p)
	if !p.on_top {
		// (no layer shell here: a normal window, as large as the picture)
		natural := pin_size(shot.size, shot.scale, 1)
		zoom := min(1, PIN_WINDOW_FIRST_MOST.x / natural.x, PIN_WINDOW_FIRST_MOST.y / natural.y)
		size := pin_size(shot.size, shot.scale, zoom)
		size = {max(size.x, PIN_WINDOW_LEAST.x), max(size.y, PIN_WINDOW_LEAST.y)}
		if !host.host_open(&p.host, &app.shared, {title = i18n.tr("Pinned picture"), size = {int(size.x), int(size.y)}}, pin_build, p) {
			app_announce(app, .Bad, i18n.tr("The picture cannot be pinned"), i18n.tr("No window can open."))
			shot_free(&p.shot)
			free(p)
			return
		}
		p.place = {zoom = zoom}
		if !app.pin_fallback_said {
			app.pin_fallback_said = true
			app_announce(app, .Info, i18n.tr("Pinned in a normal window"), i18n.tr("This desktop lets no window stay above the others."))
		}
	}
	r := &app.shared.r
	p.tex = render.create_texture_rgba(r, shot.size.x, shot.size.y, mips = true)
	if p.tex == 0 {
		app_announce(app, .Bad, i18n.tr("The picture cannot be pinned"), "")
		app_host_close(app, &p.host)
		shot_free(&p.shot)
		free(p)
		return
	}
	// (mips: a pin made smaller stays sharp)
	render.update_texture_rgba(r, p.tex, 0, 0, shot.size.x, shot.size.y, shot.rgba)
	app_standard_follow(app, &p.host)
	p.host.input = pin_input
	p.host.close_asked = proc(h: ^host.Host) { (^Pin)(h.user).close_due = true }
	p.host.params = pin_params
	p.host.after_input = 2
	p.icons, _ = font.load_embedded(&app.shared.fonts, lucide.DATA)
	p.host.state.icon_font = p.icons
	p.gesture = Pin_Still{}
	// (no pointer anywhere until the first build places the picture: the screen stays usable from the start)
	if p.on_top { platform.set_input_region(p.host.win, nil) }
	append(&app.pins, p)
	app_wake_add(app, p.host.win)
	host.host_show(&p.host)
	p.visible = true
	p.host.settle = max(p.host.settle, 3)
}

// The picture file at `path` (PNG, JPEG, WebP, BMP) pinned: read and decoded by a task of the chores, pinned once it
// is (pins_frame). The history's "Pin" action.
pin_picture :: proc(app: ^App, path: string) {
	work := new(Pin_Load)
	work^ = {path = strings.clone(path), app = app}
	run :: proc(data: rawptr) {
		work := (^Pin_Load)(data)
		if bytes, err := os.read_entire_file(work.path, context.allocator); err == nil {
			img, _, ok := pic.decode(bytes)
			delete(bytes)
			// (a file of the history: its pixels are the screen's; its scale is not known, 1 is the safe guess)
			if ok { work.shot, work.ok = {rgba = img.pixels, size = {img.width, img.height}, source = .Region, scale = 1}, true }
		}
		app := work.app
		if _, done := sync.atomic_compare_exchange_strong(&work.state, .Running, .Done); done {
			app_wake(app)
			return
		}
		pin_load_free(work)   // (cliche is ending: nobody takes it)
	}
	if !tasks.add(ui.chores(), run, work) {
		pin_load_free(work)
		return
	}
	append(&app.pin_loads, work)
}

@(private = "file")
pin_load_free :: proc(work: ^Pin_Load) {
	delete(work.path)
	shot_free(&work.shot)
	free(work)
}

// A frame of each pin shown, then what it decided; the files read meanwhile pinned; the pins closed freed. Between the
// other windows' frames (app_frames): a pin may open or close here.
pins_frame :: proc(app: ^App) {
	for i := 0; i < len(app.pin_loads); {
		work := app.pin_loads[i]
		if sync.atomic_load(&work.state) != .Done { i += 1; continue }
		ordered_remove(&app.pin_loads, i)
		if work.ok {
			pin_open(app, work.shot)
			work.shot = {}
		} else {
			app_announce(app, .Bad, i18n.tr("The picture cannot be pinned"), i18n.tr("The file is not a picture cliche reads, or it is gone."))
		}
		pin_load_free(work)
	}
	for p in app.pins {
		if !p.visible || p.closed { continue }
		host.host_frame(&p.host)
		pin_after_frame(p)
	}
	for i := len(app.pins) - 1; i >= 0; i -= 1 {
		p := app.pins[i]
		if !p.closed { continue }
		ordered_remove(&app.pins, i)
		free(p)
	}
}

// The pins shown: the loop waits on them too (app_wait).
pins_shown :: proc(app: ^App, shown: ^[dynamic]^host.Host) {
	for p in app.pins { if p.visible && !p.closed { append(shown, &p.host) } }
}

// Every pin closed, every file being read given up: cliche ends. The textures go while the renderer is there.
pins_close_all :: proc(app: ^App) {
	for p in app.pins { if !p.closed { pin_close(p) } }
	for p in app.pins { free(p) }
	delete(app.pins)
	app.pins = nil
	for work in app.pin_loads {
		// (a task still running frees its own work)
		if _, given_up := sync.atomic_compare_exchange_strong(&work.state, .Running, .Given_Up); !given_up { pin_load_free(work) }
	}
	delete(app.pin_loads)
	app.pin_loads = nil
}

// The window goes, with its picture. Not inside its own frame. (Never the renderer's own window: pin_open.)
@(private = "file")
pin_close :: proc(p: ^Pin) {
	app := p.app
	if p.tex != 0 { render.destroy_texture(&app.shared.r, p.tex) }
	p.tex = 0
	shot_free(&p.shot)
	p.closed = true
	// (no other thread wakes a window about to go)
	app_wake_remove(app, p.host.win)
	app_host_close(app, &p.host)
	p.visible = false
}

////////////////////////////////
// The window

// Each build: the theme, as the main window has it (its menu's colours).
@(private = "file")
pin_params :: proc(h: ^host.Host, bp: ^ui.Build_Params) {
	p := (^Pin)(h.user)
	app := p.app
	a := app.settings.appearance
	choice := prefs_page.appearance_choice(a)
	choice.glow = 1
	ui.theme_show(&app.shared.theme, app.themes_file.all[:], choice, &p.theme_shown, render.blend_space(&app.shared.r))
	bp.base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(28)}, font = app.shared.font, font_size = a.font_size, text_pad = 6, cursor = .Arrow}
}

// The pointer on the picture: a drag, the wheel, a double click, a right click. While its menu is open, everything
// goes to the menu.
@(private = "file")
pin_input :: proc(h: ^host.Host, events: []platform.Event) -> []platform.Event {
	p := (^Pin)(h.user)
	if p.menu_open || ui.menu_any_open() { return events }
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		#partial switch e.kind {
		case .Mouse_Press:
			if !pin_hit(p, e.pos) { break }
			#partial switch e.button {
			case .Left:
				double := time.tick_diff(p.last_press, e.stamp) < PIN_DOUBLE_CLICK_MS * time.Millisecond &&
					abs(e.pos.x - p.last_press_at.x) <= PIN_DOUBLE_CLICK_PX && abs(e.pos.y - p.last_press_at.y) <= PIN_DOUBLE_CLICK_PX
				p.last_press, p.last_press_at = e.stamp, e.pos
				if double { p.close_due = true; continue }
				// (a normal window moves by its title bar)
				if p.on_top { p.gesture = Pin_Dragging{grab = e.pos - p.place.at} }
				continue
			case .Right:
				p.menu_due, p.menu_at = true, e.pos
				continue
			}
		case .Mouse_Move:
			if g, dragging := p.gesture.(Pin_Dragging); dragging {
				p.place = pin_drag_to(p.place, p.shot.size, p.shot.scale, e.pos, g.grab, p.window)
				h.settle = max(h.settle, 1)
				continue
			}
		case .Mouse_Release:
			if _, dragging := p.gesture.(Pin_Dragging); dragging && e.button == .Left {
				p.gesture = Pin_Still{}
				continue
			}
		case .Scroll:
			if !pin_hit(p, e.pos) || e.delta.y == 0 { break }
			pin_zoom(p, e.pos, e.delta.y)
			continue
		}
		append(&out, e)
	}
	return out[:]
}

// The wheel: an overlay zooms around the pointer; a normal window takes the picture's new size.
@(private = "file")
pin_zoom :: proc(p: ^Pin, pointer: [2]f32, notches: f32) {
	if p.on_top {
		p.place = pin_zoom_at(p.place, pointer, notches)
	} else {
		p.place = {zoom = clamp(p.place.zoom * math.pow(PIN_ZOOM_STEP, notches), PIN_ZOOM_MIN, PIN_ZOOM_MAX)}
		size := pin_size(p.shot.size, p.shot.scale, p.place.zoom)
		platform.set_size(p.host.win, {int(max(size.x, PIN_WINDOW_LEAST.x)), int(max(size.y, PIN_WINDOW_LEAST.y))})
	}
	p.host.settle = max(p.host.settle, 2)
}

@(private = "file")
Pin_Draw :: struct { tex: render.Texture, rect: draw.Rect, edge: draw.Color, px: f32 }

@(private = "file")
pin_build :: proc(h: ^host.Host, size: host.Vec2) {
	p := (^Pin)(h.user)
	p.window = {size.x, size.y}
	if !p.placed && size.x > 0 && size.y > 0 {
		if p.on_top { p.place = pin_place_first(p.shot.size, p.shot.scale, p.window) }
		p.placed = true
	}
	if !ui.menu_any_open() && ui.key_press(.Escape) { p.close_due = true }

	d := ui.frame_new(Pin_Draw)
	d^ = {tex = p.tex, rect = {p.place.at, p.place.at + pin_size(p.shot.size, p.shot.scale, p.place.zoom)}, edge = {0, 0, 0, 0.35}, px = max(math.round(ui.scale()), 1)}
	_, dragging := p.gesture.(Pin_Dragging)
	ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(size.x), height = ui.px(size.y), cursor = dragging ? platform.Cursor.Grabbing : platform.Cursor.Grab})
	ui.custom("###pin", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Pin_Draw)(user)
		if d.tex == 0 { return }
		draw.image(dc, d.tex, d.rect)
		// (a hairline: a pin on a picture of the same colours still shows its edge)
		draw.rect(dc, draw.rect_pad(d.rect, d.px), d.edge, 0, d.px)
	}, d)

	if p.menu_due {
		p.menu_due = false
		ui.menu_open(PIN_MENU, p.menu_at, search = false)
	}
	if ui.menu(PIN_MENU) {
		if ui.menu_item(i18n.tr("Copy the picture"), icon = lucide.CLIPBOARD_COPY).clicked { pin_copy(p) }
		if ui.menu_item(i18n.tr("Save the picture"), icon = lucide.SAVE).clicked { pin_save(p) }
		ui.menu_separator()
		if ui.menu_item(i18n.tr("Close the pinned picture"), platform.key_text(platform.Key.Escape), icon = lucide.X).clicked { p.close_due = true }
	}
	p.menu_open = ui.menu_is_open(PIN_MENU)
}

// After the frame: the input region follows the picture (the whole window while its menu is open: a press elsewhere
// closes it); a close is acted on.
@(private = "file")
pin_after_frame :: proc(p: ^Pin) {
	if p.close_due {
		p.close_due = false
		pin_close(p)
		return
	}
	if !p.on_top || !p.placed { return }
	if p.menu_open {
		if !p.input_whole {
			platform.clear_input_region(p.host.win)
			p.input_whole = true
		}
		return
	}
	rect := pin_input_rect(p.place, p.shot.size, p.shot.scale)
	if p.input_whole || rect != p.input_set {
		rects := [1][4]int{rect}
		platform.set_input_region(p.host.win, rects[:])
		p.input_set, p.input_whole = rect, false
	}
}

// Its picture on the clipboard: its PNG made on the worker, as the editor's Ctrl+C (said where cliche says things).
@(private = "file")
pin_copy :: proc(p: ^Pin) {
	worker_send(&p.app.worker, Job_Copy_Encode{shot = pin_shot_copy(p)})
}

// Its picture saved as the editor's Ctrl+S: the default folder and name.
@(private = "file")
pin_save :: proc(p: ^Pin) {
	app := p.app
	worker_send(&app.worker, Job_Save{shot = pin_shot_copy(p), folder = strings.clone(app.settings.folder), pattern = strings.clone(app.settings.name_pattern)})
}

// A copy of the picture the worker owns (the pin keeps its own while it shows).
@(private = "file")
pin_shot_copy :: proc(p: ^Pin) -> Shot {
	s := p.shot
	s.rgba = make([]u8, len(p.shot.rgba))
	copy(s.rgba, p.shot.rgba)
	return s
}
