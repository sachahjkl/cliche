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
- **Wayland:** a layer surface cannot move. The overlay is closed and another is made over the new output.

**The subtle point:** started from the tray, the overlay is the program's first window, the one that holds the
renderer, and that window cannot be closed while the program runs. Before `overlay_move`, the overlay of a program
started from the tray stayed on the output of its first trigger, the primary in practice. On Windows and X11 it moves
now. On Wayland the first window still stays on its output (see `ROADMAP.md`).
