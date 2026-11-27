package cliche

import "core:strings"
import "core:testing"
import "gt:debug"
import "gt:ui"

// The panel lists cliche's state machines, and a tool's set reaches the App's settings (src/md/features/debug-panel.md).
// On a State with no window: a machine with no renderer (the release's runner) runs it too.
@(test)
the_debug_panel_shows_the_state_and_sets_a_setting :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.settings.magnifier = true
	state: ui.State
	ui.init(&state, nil, nil)
	defer ui.destroy(&state)
	debug.panel(&state, DEBUG_PANEL, debug_panel_build_for_test, app)
	sb := strings.builder_make(context.temp_allocator)
	debug.list(&state, &sb)
	listed := strings.to_string(sb)
	for path in ([]string{"Cliche/Capture/flow", "Cliche/Overlay/mode", "Cliche/Recording/state", "Cliche/Region/magnifier", "Cliche/Region"}) {
		testing.expectf(t, strings.contains(listed, path), "%s is not listed", path)
	}
	testing.expect_value(t, debug.set(&state, "Cliche/Region/magnifier", "false"), "")
	testing.expect(t, !app.settings.magnifier)
}
