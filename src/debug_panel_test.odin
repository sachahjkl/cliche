package cliche

import "core:strings"
import "core:testing"
import "gt:debug"
import "gt:testkit/session"
import "gt:ui"

// The panel lists cliche's state machines, and a tool's set reaches the App's settings (src/md/features/debug-panel.md).
@(test)
the_debug_panel_shows_the_state_and_sets_a_setting :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.settings.magnifier = true
	s := session.start(t, {size = {800, 600}, build = proc(s: ^session.Session) { ui.label("page###page") }})
	debug.panel(s.state, DEBUG_PANEL, debug_panel_build_for_test, app)
	sb := strings.builder_make(context.temp_allocator)
	debug.list(s.state, &sb)
	listed := strings.to_string(sb)
	for path in ([]string{"Cliche/Capture/flow", "Cliche/Overlay/mode", "Cliche/Recording/state", "Cliche/Region/magnifier", "Cliche/Region"}) {
		testing.expectf(t, strings.contains(listed, path), "%s is not listed", path)
	}
	testing.expect_value(t, debug.set(s.state, "Cliche/Region/magnifier", "false"), "")
	testing.expect(t, !app.settings.magnifier)
}
