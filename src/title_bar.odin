package cliche

// cliche's own title bar, as every program of the toolkit draws its own (src/md/features/title-bar.md): on its normal
// windows, the history window (with its settings and its workflows) and each editor. window.system_title off, the
// default: the window has none of the system's decorations, and this bar is its title bar (its empty parts move the
// window, a double click maximises it, the toolkit's window buttons at its right end). On: the system draws the title
// bar, and this bar is not built. The pins and the overlays have no title bar of either kind.

import "core:fmt"
import "core:math"
import host "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

// The title bar's height, in ems (dense).
TITLE_BAR_EM :: 2.4

// The title bar of `h`, the window being built: cliche's mark, `title`, then the window's minimise, maximise and close.
// Nothing while the system draws the title bar (window.system_title).
window_title_bar :: proc(h: ^host.Host, title: string, em: f32) {
	if h.win == nil || !platform.is_integrated_title(h.win) { return }
	ui.next({width = ui.fill(), height = ui.px(math.round(ui.dense(em * TITLE_BAR_EM)))})
	if ui.title_bar("###titlebar") {
		ui.space(ui.SPACE_2)
		ui.icon(lucide.SCAN, math.round(em * 1.5), ui.color("accent"))
		ui.space(ui.ICON_GAP)
		// (a text that is not clickable moves the window too)
		ui.next({width = ui.text_size(), height = ui.pct(1)})
		ui.label(fmt.tprintf("%s###apptitle", title))
		ui.spacer(ui.fill())
		_, _ = ui.window_buttons()
	}
	ui.hline(ui.fill())
}

// window.system_title changed: each normal window takes the title bar asked at once, where the desktop lets it. The
// views' windows follow their owner's by themselves (the toolkit's step).
app_title_follow :: proc(app: ^App) {
	integrated := !app.settings.system_title
	if app.history_window.opened { window_title_set(app.history_window.host.win, integrated) }
	for ed in app.editors { window_title_set(ed.host.win, integrated) }
}

@(private = "file")
window_title_set :: proc(w: ^platform.Window, integrated: bool) {
	if w == nil || platform.is_offscreen(w) || platform.is_integrated_title(w) == integrated { return }
	platform.set_integrated_title(w, integrated)
}
