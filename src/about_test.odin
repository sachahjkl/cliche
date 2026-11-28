package cliche

import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:ui"

// About's metadata, copy formatters and in-app What's new jump work with no window.
@(test)
about_info_and_whats_new_jump :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	prefs_register(&app.prefs, context.temp_allocator)
	app.settings = prefs_read(&app.prefs)
	app.backend = .Wayland_Image_Copy
	defer {
		settings_mode_free(app)
		prefs_page.changelog_destroy(&app.changelog)
		settings_free(&app.settings)
		config.prefs_destroy(&app.prefs)
	}

	links: [1]ui.About_Link
	info := about_info(app, &links)
	testing.expect_value(t, info.name, APP_TITLE)
	testing.expect_value(t, info.version, APP_VERSION)
	testing.expect_value(t, info.licence, "MIT")
	testing.expect_value(t, info.website_url, ABOUT_WEBSITE_URL)
	testing.expect_value(t, info.releases_url, ABOUT_RELEASES_URL)
	testing.expect(t, info.on_whats_new != nil, "What's new callback is set")

	vtext := ui.about_version_text(info)
	testing.expect(t, strings.contains(vtext, APP_TITLE) && strings.contains(vtext, APP_VERSION) && strings.contains(vtext, ui.VERSION), "version text holds program and toolkit versions")
	dtext := ui.about_diagnostics_text(info)
	testing.expect(t, strings.contains(dtext, APP_VERSION) && strings.contains(dtext, ui.VERSION) && strings.contains(dtext, "Capture: Wayland_Image_Copy"), "diagnostics text holds versions and capture backend")

	// What's new opens settings directly on the built-in changelog page.
	info.on_whats_new(info.user)
	testing.expect(t, app.history_window.settings_mode.open, "settings opened")
	testing.expect_value(t, app.history_window.settings_mode.page.current, prefs_page.CHANGELOG_PAGE)
	testing.expect(t, app.changelog.english != "", "embedded changelog loaded")

	// About is available in every mode of the main window, and blocks page keys while open.
	testing.expect(t, .About in history_enabled(app))
	app.history_window.about_open = true
	testing.expect(t, history_views_open_for_test(app))
}
