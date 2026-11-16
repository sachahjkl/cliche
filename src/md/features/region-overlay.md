# The region's overlay

The selection of a region covers the whole desktop: one overlay window over each output, all showing the frozen picture
of the desktop, all sharing one selection. A rectangle can start on one output and end on another: the cut is taken from
the frozen desktop, which holds every output.

## One window per output, one selection

One window per output, not one window over the union of the outputs:

- Wayland gives no surface over several outputs: a layer surface is made for one output.
- Outputs of different scales cannot share one window without one of them drawn at the wrong scale.

The windows are only views. The state (the selection, the pointer, the window framed, the decision) is the overlay's,
once, in desktop coordinates (logical pixels). Each window converts its events with its own output's place and scale,
then feeds the same state. Each window draws its own output's part of the picture and of the selection.

**The subtle point:** a drag that crosses to another output keeps sending its events to the window where it started:
Wayland's implicit grab, X11's, Windows' `SetCapture`. The points come outside that window's surface; converted with
its output's place, they land on the other output. So a drag needs no hand-over between windows. If a system gives the
events to the other window instead, the result is the same: the state is shared.

Any input redraws every window: the selection that one window changed shows on the others.

The keyboard goes to one of the windows (each asks for it; the system picks one). The keys act on the shared state, so
it does not matter which.

## Bounds

- A screenshot: the selection stays in the box around every output. Between outputs of different sizes the box holds
  areas no output shows; the cut is transparent there, as in "all the screens".
- A recording: the recorder records one output, so the selection stays on the output where the press started. The
  record overlay then covers that output.
- Enter with nothing chosen takes the output under the pointer, not the whole desktop.

## The windows follow the outputs

At each trigger the windows are matched to the outputs the worker read: a window whose output is still there stays. For
an output with no window, a spare window moves there where the system lets it (`platform.overlay_move`: Windows, X11),
else a new window opens. The windows left over close.

**The order is fixed:** open the new windows first, then close the old ones. Started from the tray, an overlay window is
the program's first window, the one that holds the renderer. Closing it first would end the renderer, and the frozen
picture's texture with it. The toolkit hands the renderer to another window when the first one closes (`host_close`:
the toolkit's `first-window.md`).

A `Host` stays where it is while it is open, so each window is on the heap (`Overlay.windows`). One procedure closes and
frees a window (`overlay_window_close`); the shutdown frees what is left (`overlay_free`).

## No overlay window: one fullscreen window

A desktop with no layer shell (GNOME on Wayland) cannot place a window on an output. There the overlay is one fullscreen
window that the compositor places, and the selection stays on the output it covers (`overlay_prepare` reads it). Refused:
several fullscreen windows there, since the compositor can put them all on the same output.
