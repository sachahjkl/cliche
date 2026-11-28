package cliche

// cliche's About modal, built on gui_toolkit's ui.about_modal (gui_toolkit docs/about.md): logo, version, toolkit
// version, licence, in-app "What's new", links, and non-blocking diagnostics from state already held on the interface
// thread. Opened from the tray menu or the command palette (About Cliche).

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"

ABOUT_WEBSITE_URL    :: "https://cliche.froment.software/"
ABOUT_RELEASES_URL   :: "https://cliche.froment.software/changelog/"
ABOUT_REPOSITORY_URL :: "https://github.com/sachahjkl/cliche"

// Shows the main window with the About modal open (tray menu).
about_show :: proc(app: ^App) {
	history_window_show(app)
	app.history_window.about_open = true
}

// Jumps to the in-app What's new page in the settings (About's primary action, and the update toast).
about_whats_new :: proc(app: ^App) {
	if app.changelog.english == "" { app.changelog.english = CHANGELOG }
	if app.history_window.opened && !app.history_window.visible { history_window_show(app) }
	settings_enter(app)
	prefs_page.show(&app.history_window.settings_mode.page, &app.prefs, settings_options(app), prefs_page.CHANGELOG_PAGE)
}

// Non-blocking diagnostics lines from state already held by App (no driver or system probes here).
about_diagnostics :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	info := render.adapter_info(&app.shared.r)
	if info.name != "" {
		if info.api != "" {
			fmt.sbprintf(&b, "Renderer: %s (%s)", info.name, info.api)
		} else {
			fmt.sbprintf(&b, "Renderer: %s", info.name)
		}
	}
	if app.backend != .None {
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		fmt.sbprintf(&b, "Capture: %v", app.backend)
	}
	return strings.to_string(b)
}

// Metadata for ui.about_modal; `links` lives on the caller's stack for the build.
about_info :: proc(app: ^App, links: ^[1]ui.About_Link) -> ui.About_Info {
	hw := &app.history_window
	links^ = {
		{label = i18n.tr("Repository"), url = ABOUT_REPOSITORY_URL},
	}
	logo_tex: render.Texture
	if l, ok := hw.about_logo.?; ok { logo_tex = l.texture }
	return {
		name         = APP_TITLE,
		version      = APP_VERSION,
		licence      = "MIT",
		copyright    = "© 2026 Froment Software",
		logo         = logo_tex,
		icon         = lucide.SCAN,
		icon_font    = hw.icons,
		on_whats_new = proc(user: rawptr) { about_whats_new((^App)(user)) },
		website_url  = ABOUT_WEBSITE_URL,
		releases_url = ABOUT_RELEASES_URL,
		links        = links[:],
		diagnostics  = about_diagnostics(app),
		user         = app,
	}
}

// Builds the About modal inside history_dialogs while open.
about_modal :: proc(app: ^App) {
	hw := &app.history_window
	if !hw.about_open { return }
	links: [1]ui.About_Link
	ui.about_modal("about", &hw.about_open, about_info(app, &links))
}
