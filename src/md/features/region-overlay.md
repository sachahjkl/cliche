# The region's overlay

The selection of a region is one overlay window over one output, the output the pointer is on at the trigger
(`gt:capture`'s `pointer`). It shows the frozen picture of that output, so what the person frames is what was there.

## One output, not the whole desktop

One window per output, not one over the union of the outputs:

- Wayland gives no surface over several outputs: a layer surface is made for one output.
- Outputs of different scales cannot share one window without one of them drawn at the wrong scale.

So a region is taken on one output. To take one on another output, the person puts the pointer there and triggers again.

## The overlay follows the pointer

At each trigger, if the pointer is on another output than the overlay's, the overlay goes there:

- **Windows, X11:** the window moves (`platform.overlay_move`), at the new output's size and scale.
- **Wayland:** a layer surface cannot move. A new overlay opens over the new output, then the old one closes.

**The subtle point:** started from the tray, the overlay is the program's first window, the one that holds the
renderer. Closing it first would end the renderer, and the frozen picture's texture with it. So the order is fixed:
open the new one, then close the old one. The toolkit then hands the renderer to the new one (`host_close` of the
first window: the toolkit's `first-window.md`).

A `Host` stays where it is while it is open, so the overlay has two places for its window (`Overlay.hosts`) and a
pointer to the one in use (`Overlay.host`): the new window opens in the free place. Refused: a heap `Host` per
opening, which the program would have to free on every path that closes it.
