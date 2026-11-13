package cliche

// cliche's licence (gt:licence, gui_toolkit docs/licence.md): a signed key, checked on this computer with no network. A
// licence changes nothing of what cliche does: it says who supports it. The settings' General page shows it under its
// preferences: whose it is, or a way to buy one, a key to paste, a file to choose, Remove.
//
// The states: unknown until the store's first read comes (read false), which the section asks for when it is first
// shown; then the status read last. Each change (a key, a file, Remove) is one task at a time (busy): it writes, reads
// the status again, and its answer comes at a next build of the main window. The store's file is touched only in those
// tasks, never on the interface's thread.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import licence "gt:licence"
import "gt:platform"
import "gt:ui"
import cliche_licence "licence"

// Where a licence is bought: the site's pricing page.
PRICING_URL :: "https://cliche.froment.software/pricing/"

// What the app keeps of the licence.
Licence_View :: struct {
	store:   licence.Store,
	status:  licence.Status,   // the last read (heap allocator)
	asked:   bool,             // the first read was asked
	read:    bool,             // a status has come
	busy:    bool,             // a task on the store is on its way
	key:     ui.Text_Field,    // the key being pasted
	problem: string,           // why the last install failed (owned; "": none)
}

@(private = "file")
Licence_Do :: enum u8 { Read, Install, Install_File, Remove }

@(private = "file")
Licence_Job :: struct {
	app:    ^App,
	act:    Licence_Do,
	text:   string,            // the key, or the file (heap)
	err:    licence.Error,
	status: licence.Status,    // read after the change (heap)
}

// `memory`: nothing read or written (the pictures of clichetool shots).
licence_init :: proc(app: ^App, memory := false) {
	// (a debug build accepts the development pair: the tests and the pictures register with it)
	licence.store_init(&app.licence.store, {product = cliche_licence.PRODUCT, program = APP_NAME, memory = memory, accept_dev = ODIN_DEBUG})
}

// After the chores have stopped: no task holds the store any more.
licence_destroy :: proc(app: ^App) {
	l := &app.licence
	licence.status_destroy(&l.status, runtime.heap_allocator())
	licence.store_destroy(&l.store)
	ui.field_wipe(&l.key)
	ui.field_destroy(&l.key)
	delete(l.problem)
	l^ = {}
}

@(private = "file")
licence_run :: proc(app: ^App, act: Licence_Do, text: string) {
	a := runtime.heap_allocator()
	j := new(Licence_Job, a)
	j^ = {app = app, act = act, text = strings.clone(text, a)}
	app.licence.busy, app.licence.asked = true, true
	work :: proc(d: rawptr) {
		j := (^Licence_Job)(d)
		s := &j.app.licence.store
		switch j.act {
		case .Read:
		case .Install:      j.err = licence.store_install(s, j.text)
		case .Install_File: j.err = licence.store_install_file(s, j.text)
		case .Remove:       if !licence.store_remove(s) { j.err = .Not_Written }
		}
		j.status = licence.store_read(s, runtime.heap_allocator())
	}
	done :: proc(d: rawptr, _: u64) {
		j := (^Licence_Job)(d)
		app := j.app
		l := &app.licence
		licence.status_destroy(&l.status, runtime.heap_allocator())
		l.status, j.status = j.status, {}
		l.read, l.busy = true, false
		delete(l.problem)
		l.problem = ""
		if j.err != .None {
			l.problem = strings.clone(licence_error_words(j.err))
		} else {
			#partial switch j.act {
			case .Install, .Install_File:
				ui.field_wipe(&l.key)
				app_announce(app, .Good, "Licence registered: thank you")
			case .Remove:
				app_announce(app, .Good, "Licence removed")
			}
		}
		licence_job_free(d)
	}
	// (the main window gone first: the job is freed, the window's state with it)
	ui.task(&app.history_window.host.state, work, done, j, licence_job_free)
}

@(private = "file")
licence_job_free :: proc(d: rawptr) {
	a := runtime.heap_allocator()
	j := (^Licence_Job)(d)
	licence.status_destroy(&j.status, a)
	delete(j.text, a)
	free(j, a)
}

// What went wrong, in cliche's words.
@(private = "file")
licence_error_words :: proc(e: licence.Error) -> string {
	#partial switch e {
	case .Wrong_Product: return "This licence is not cliche's."
	case .Bad_Signature: return "This key is not a valid licence of cliche: check that it was copied whole."
	case .No_Public_Key: return "This build of cliche accepts no licence yet."
	case .Not_Read:      return "The licence file cannot be read."
	case .Not_Written:   return "The licence cannot be saved."
	}
	return licence.error_text(e)
}

// The Licence section, under the General page's preferences (prefs_page Options.page_foot).
licence_section :: proc(app: ^App, em: f32) {
	l := &app.licence
	// (the store is read once the section is first shown: nothing is read at the start for it)
	if !l.asked { licence_run(app, .Read, "") }
	ui.spacer(ui.px(em * 1.2))
	ui.next({width = ui.fill(), height = ui.px(em * 1.6), font_size = math.round(em * 1.02), text_pad = 0})
	ui.label("Licence###licence_title")
	ui.spacer(ui.px(em * 0.3))
	switch {
	case !l.read:
		if ui.tags("weak") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph("Reading the licence…###licence_state")
		}
	case l.status.registered:
		lic := l.status.licence
		ui.next({width = ui.fill(), text_pad = 0})
		ui.paragraph(fmt.tprintf("Registered to %s (%s). Thank you for supporting cliche.###licence_state", lic.name, licence.edition_title(cliche_licence.PRODUCT, lic.edition)))
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.text_size(em * 0.6), height = ui.px(math.round(em * 1.9))})
		if ui.button("Remove the licence###licence_remove", intent = .Danger, face = .Ghost, disabled = l.busy).clicked {
			licence_run(app, .Remove, "")
		}
	case:
		ui.next({width = ui.fill(), text_pad = 0})
		ui.paragraph("Unregistered. cliche is free; a licence supports its work.###licence_state")
		if l.status.stored {
			// (a key is there, but it does not check out: said, not hidden)
			if ui.tags("bad") {
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("The licence stored here is not valid: %s###licence_stored", licence_error_words(l.status.err)))
			}
		}
		ui.spacer(ui.px(em * 0.3))
		if ui.hint_action("###licence_buy", "Support cliche: buy a licence", intent = .Primary).clicked { ui.open(PRICING_URL, .Url) }
		ui.spacer(ui.px(em * 0.6))
		h := ui.px(math.round(em * 1.9))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(id = "###licence_row") {
			ui.next({width = ui.fill(), height = h})
			res := ui.line_edit("###licence_key", &l.key, "Paste a licence key")
			key := strings.trim_space(ui.field_string(&l.key))
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.6), height = h})
			register := ui.button("Register###licence_register", intent = .Primary, disabled = l.busy || key == "")
			if (register.clicked || res.committed) && key != "" && !l.busy { licence_run(app, .Install, key) }
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.6), height = h})
			if ui.button("Choose a file…###licence_file", disabled = l.busy).clicked { licence_choose_file(app) }
		}
	}
	if l.problem != "" {
		ui.spacer(ui.px(em * 0.3))
		if ui.tags("bad") {
			ui.next({width = ui.fill(), text_pad = 0})
			ui.paragraph(fmt.tprintf("%s###licence_problem", l.problem))
		}
	}
}

// The system's Open dialog, then the file installed: both off the interface's thread.
@(private = "file")
licence_choose_file :: proc(app: ^App) {
	hw := &app.history_window
	d := licence.file_dialog(cliche_licence.PRODUCT, "Choose a licence file", "cliche licence")
	d.owner = hw.host.win
	ui.file_dialog(&hw.host.state, .Open, d, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status != .Chosen || len(r.paths) == 0 { return }
		app := (^App)(user)
		// (licence_run copies the path: the result's are freed after this call)
		licence_run(app, .Install_File, r.paths[0])
	}, app)
}
