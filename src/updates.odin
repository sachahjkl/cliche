package cliche

// Updates: gui_toolkit's Updater (gt:update, its docs/update.md) checks cliche's latest release a while after the start
// and then every day, downloads the program it names, checks it against its signed manifest (src/update: cliche's product
// and key) and puts it in place of this one, as in every program of the toolkit. Only the installed copy does it by itself
// (update.auto): a build, or a copy run where it was unpacked, is updated when the settings' Check now asks. Once a new
// cliche is in place, this one gives way to it as soon as nothing is shown or under way: the new one starts in the
// notification area. A copy from the Nix store is left to Nix.

import "core:fmt"
import "core:log"
import "core:strings"
import process "gt:process"
import prefs_page "gt:prefs_page"
import setup "gt:setup"
import update "gt:update"
import cliche_update "update"

// The folder of the latest release's files: its manifests (update-<platform>.json and .sig) and its programs. The default
// of update.base_url, which a mirror or a test changes.
UPDATE_FOLDER :: "https://github.com/sachahjkl/cliche/releases/latest/download/"

// What the updates hold in the App.
Updates :: struct {
	updater:   ^update.Updater,
	serial:    int,    // the updater's state last said
	installed: bool,   // this cliche is the installed copy (the worker's answer to Job_Setup_Facts): it updates itself
	restart:   bool,   // cliche starts again once this one has ended (app_run)
	settings:  bool,   // ... on its settings (Restart now was pressed there)
}

// At the start, once the preferences are read and the worker runs: whether this is the installed copy comes from the
// worker (updates_facts).
updates_start :: proc(app: ^App) {
	folder, _ := prefs_page.update_source(&app.prefs)
	app.updates.updater = update.updater_start({
		product = cliche_update.PRODUCT, folder = folder != "" ? folder : UPDATE_FOLDER, current = APP_VERSION,
		exe = process.executable_path(), user_agent = fmt.tprintf("cliche/%s", APP_VERSION),
		// (the updater's thread: the loop wakes, and updates_follow reads the state)
		news = app_wake, user = app,
	})
	worker_send(&app.worker, Job_Setup_Facts{})
	updates_auto(app)
}

// The worker said whether this is the installed copy.
updates_facts :: proc(app: ^App, r: Result_Setup_Facts) {
	app.updates.installed = r.installed
	updates_auto(app)
}

// update.auto, read again when the preferences change.
updates_auto :: proc(app: ^App) {
	if app.updates.updater == nil { return }
	auto := app.settings.update_auto && app.updates.installed
	update.set_auto(app.updates.updater, auto ? .Install : .Off)
}

// At the end, before the windows go: no news after it.
updates_stop :: proc(app: ^App) {
	update.updater_stop(app.updates.updater)
	app.updates.updater = nil
}

// At each turn of the loop: what changed is said, and an update in place takes over once nothing is shown or under way.
updates_follow :: proc(app: ^App) {
	u := &app.updates
	if u.updater == nil { return }
	st := update.status(u.updater)
	if st.serial != u.serial {
		u.serial = st.serial
		if app.history_window.visible { app.history_window.host.settle = max(app.history_window.host.settle, 3) }   // (the settings show the state)
		// (the history's footer shows the phase with its badge: a toast says only what the badge cannot, once)
		if words, bad := update.notice(st); words != "" { app_announce(app, bad ? .Bad : .Good, words) }
		// (the installed copy: its manifest and Settings > Apps say the new version)
		if st.phase == .Installed { worker_send(&app.worker, Job_Setup_Updated{version = strings.clone(st.version)}) }
	}
	if st.phase == .Installed && !app.quit && updates_idle(app) { app_restart(app) }
}

// Nothing is shown nor under way: no window, no capture, no recording, no workflow running.
@(private = "file")
updates_idle :: proc(app: ^App) -> bool {
	if app.overlay.visible || app.history_window.visible || app.record_overlay.visible || len(app.runs) > 0 { return false }
	for ed in app.editors { if ed.visible { return false } }
	if _, idle := app.flow.(Flow_Idle); !idle { return false }
	if _, idle := app.record.(Record_Idle); !idle { return false }
	return true
}

// cliche starts again once this one has ended (it holds the single instance until then): an update put in place, or
// Restart now (`settings`: the new one opens its settings).
app_restart :: proc(app: ^App, settings := false) {
	app.updates.restart, app.updates.settings = true, settings
	app.quit = true
}

// At the very end of app_run, the instance let go: the program again, when a restart was asked.
updates_launch :: proc(app: ^App) {
	if !app.updates.restart { return }
	exe := process.executable_path()
	if !setup.launch(exe, app.updates.settings ? []string{"--settings"} : nil) { log.errorf("%s does not start", exe) }
}

// "Check for updates": its answer is said whatever it is.
update_check_asked :: proc(app: ^App) {
	if app.updates.updater != nil { update.check_now(app.updates.updater) }
}

// What the settings' page is given for the Updates page: the Updater, and Restart now.
updates_page_restart :: proc(user: rawptr) { app_restart((^App)(user), settings = true) }
