package cliche

// cliche's licence (gt:licence, gui_toolkit docs/licence.md): a signed key, checked on this computer with no network. A
// licence changes nothing of what cliche does: it says who supports it. The settings show it on the toolkit's Licence
// page (prefs_page.Licence): its state, Buy a licence, a key to paste, a file to choose, Remove. The page's tasks answer
// in the main window (the history's, where the settings are), so the store is opened with that window
// (licence_attach); its file is touched only in those tasks, never on the interface's thread.

import prefs_page "gt:prefs_page"
import cliche_licence "licence"

// Where a licence is bought: the site's pricing page.
PRICING_URL :: "https://cliche.froment.software/pricing/"

// `memory`: nothing read or written (the pictures of clichetool shots). Kept until the main window opens.
licence_init :: proc(app: ^App, memory := false) {
	// (the options wait in the page's own state until licence_attach gives it its window)
	app.licence.options.store.memory = memory
}

// The main window is open: the store, and its first read, answered in that window (it is hidden, never closed, until
// the end).
licence_attach :: proc(app: ^App) {
	if app.licence.store != nil { return }
	// (a debug build accepts the development pair: the tests and the pictures register with it)
	prefs_page.licence_init(&app.licence, &app.history_window.host.state, {
		store = {product = cliche_licence.PRODUCT, program = APP_NAME, memory = app.licence.options.store.memory, accept_dev = ODIN_DEBUG},
		name = "cliche", pricing_url = PRICING_URL, owner = app.history_window.host.win,
	})
}

// After the chores have stopped: no task holds the store any more.
licence_destroy :: proc(app: ^App) { prefs_page.licence_end(&app.licence) }
