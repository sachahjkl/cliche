#+build windows
package cliche

import win "core:sys/windows"

// The width of the system's vertical scroll bar, in logical pixels, with SCROLL_BAR_MARGIN_PX: what the scrolling
// capture leaves out of its comparison when capture.scroll_bar_px is 0. Asked at 96 dpi, so it is logical whatever the
// monitor's scale; the caller scales it to the frame's pixels. A system call: the worker calls it.
scroll_bar_auto_px :: proc() -> int {
	w := int(win.GetSystemMetricsForDpi(win.SM_CXVSCROLL, 96))
	if w <= 0 { return SCROLL_BAR_DEFAULT_PX }
	return w + SCROLL_BAR_MARGIN_PX
}
