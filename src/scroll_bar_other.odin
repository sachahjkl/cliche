#+build !windows
package cliche

// The width the scrolling capture leaves out of its comparison when capture.scroll_bar_px is 0, in logical pixels.
// No system here says how wide another program's scroll bar is (each toolkit draws its own): a fixed width that covers
// the common ones.
scroll_bar_auto_px :: proc() -> int { return SCROLL_BAR_DEFAULT_PX }
