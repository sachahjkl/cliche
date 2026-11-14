package cliche

// cliche on the user's desktop (gt:desktop): its launcher in the application menu with its icons (general.menu), and its
// start with the session, in the notification area (general.autostart). The desktop knows a program by its launcher: the
// shortcuts' portal keeps cliche's keys under that name, and KWin gives the windows' places to a program that names its
// protocol there. The worker applies them (they write files, and on Windows the registry). The install (setup_options)
// puts a copy in a folder of its own with the same launcher.

import "core:fmt"
import "core:os"
import desktop "gt:desktop"
import prefs_page "gt:prefs_page"
import setup "gt:setup"

@(rodata)
ICON_PNGS := [?]desktop.Icon{
	{16, #load("../assets/logo_16.png")},
	{32, #load("../assets/logo_32.png")},
	{64, #load("../assets/logo_64.png")},
	{128, #load("../assets/logo_128.png")},
	{256, #load("../assets/logo_256.png")},
}

@(rodata)
ENTRY_EXTRA := [?][2]string{
	// (KWin gives its window management protocol, where the windows are, only to a program that names it)
	{"X-KDE-Wayland-Interfaces", "org_kde_plasma_window_management"},
}

// What a launcher's right click offers besides cliche.
@(rodata)
ENTRY_ACTIONS := [?]desktop.Desktop_Action{
	{id = "region", name = "Capture a region", arguments = "--region"},
	{id = "screen", name = "Capture the screen", arguments = "--screen"},
	{id = "window", name = "Capture the window in front", arguments = "--window"},
	{id = "edit", name = "Capture a region and edit", arguments = "--edit"},
	{id = "color", name = "Pick a colour", arguments = "--color"},
	{id = "qr", name = "Read a QR code", arguments = "--qr"},
	{id = "ocr", name = "Read the text", arguments = "--ocr"},
	{id = "record", name = "Record a video", arguments = "--record"},
	{id = "workflows", name = "Workflows", arguments = "--workflows"},
	{id = "settings", name = "Settings", arguments = "--settings"},
}

cliche_identity :: proc() -> desktop.Identity {
	return desktop.Identity{
		name = "cliche", key = "Cliche", slug = APP_NAME,
		description = "Fast screenshots and screen recordings, shared at once.",
		vendor = "Froment Software",
		entry_marker = "X-Cliche-Integration", registry_mark = "ClicheIntegration", vendor_key = "FromentSoftware",
		manifest_name = "cliche_install.txt",
		generic_name = "Screenshot Tool", categories = "Utility;Graphics;", keywords = "screenshot;screen;capture;record;gif;qr;",
		env_prefix = "CLICHE_DESKTOP_",
		entry_extra = ENTRY_EXTRA[:],
		actions = ENTRY_ACTIONS[:],
		uninstall_arguments = "--setup",   // (Settings > Apps: the install's dialog, its Uninstall)
	}
}

// What the install knows of cliche (prefs_page.Install: its offer, its dialog, the settings' Installation page, cliche
// --install): the copy in a folder of its own, its launcher and icons, and the start with the session in the
// notification area as general.autostart says. The places of a test (CLICHE_DESKTOP_*) come from the environment.
setup_options :: proc() -> setup.Setup_Options {
	return setup.Setup_Options{
		identity = cliche_identity(), version = APP_VERSION, install_folder = APP_NAME, icons = ICON_PNGS[:], running = cliche_running,
		prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
			desktop.roots_from_env(o, proc(name: string) -> string { return os.get_env(name, context.temp_allocator) })
		},
	}
}

// The install's dialog over the main window (cliche --setup, Settings > Apps' Uninstall).
setup_show :: proc(app: ^App) {
	history_window_show(app)
	if app.history_window.opened { prefs_page.install_open(&app.install) }
}

// The launcher and the start with the session as asked, on the worker. "" when it went well, else why not.
integration_apply :: proc(menu, autostart: bool) -> string {
	if !desktop.supported() { return "" }
	o := desktop.options_make(cliche_identity())
	o.icons = ICON_PNGS[:]
	o.start_menu = menu
	o.autostart = autostart
	o.notify_system = true
	if !menu && !autostart {
		st := desktop.status(&o, context.temp_allocator)
		if st.state == .Absent { return "" }
		if r := desktop.remove(&o); r.error != .None { return fmt.tprintf("cliche cannot leave the desktop: %s", r.detail) }
		return ""
	}
	// (at each start: written again only when something is missing or runs another copy of cliche)
	if st := desktop.status(&o, context.temp_allocator); st.state == .Installed { return "" }
	if r := desktop.install(&o); r.error != .None { return fmt.tprintf("cliche cannot be put on the desktop: %s", r.detail) }
	return ""
}
