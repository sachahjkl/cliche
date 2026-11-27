# The debug panel

cliche's own state in the toolkit's debug window (gui_toolkit's `gt:debug`, its docs/debug.md): Ctrl+Alt+Shift+D in a
build with the devtools (a debug build, a test). A release has none of it: every call is empty there.

## What it shows

The state that the code holds as state machines and that a bug report asks about, read on the interface's thread:

- **Capture**: the capture flow (`flow.odin`), what the rectangle is for, the capture's backend, the desktop the worker
  read (its outputs, its windows, whether the system says where windows are), the last region.
- **Overlay**: its windows, the output each covers and its scale, its mode, the pointer, the selection, the decision.
  The bug of the magnifier frozen on a second screen was found by logging these values: they are here now.
- **Recording**: the recording's state machine (`record.odin`), its region and output, whether the recorder's thread
  runs.
- **Workflows**, **Windows**: the workflows, the runs in flight, the editors, the pins.
- **Region**: the overlay's settings (magnifier, dim, frames, confirm on release), edited live.

## Decisions

- **One panel, in the main window.** The main window is the one a person opens to look at cliche; the overlay's windows
  come and go with each capture and take the keyboard. The panel is registered when the main window opens
  (`history_window_open`), its data the `App`, which lives as long as the windows.
- **Nothing of the worker.** The panel runs on the interface's thread and reads the worker's state only as its results
  bring it (`App.desktop`, `App.backend`). Refused: reading `Worker`'s fields across threads.
- **The settings edited are not saved.** A value set in the panel changes `App.settings` until the preferences are read
  again; it is a trial, not a preference. Only numbers and booleans are offered: refused, `debug.value` on the whole
  `Settings`, whose strings the debug surface would replace with its own copies, which `settings_free` must not free.
- **Acts start what a shortcut starts** (a region, a colour, the ruler, a recording), through the same procedures as the
  tray, so a tool (`tk cdp debug-press Cliche/Region`) drives a capture with no key.
