# Scrolling capture

One tall picture of a page that scrolls, stitched from its screens. The person chooses the page on the region's overlay
(a rectangle, or a click on a framed window). Cliche then turns the mouse wheel over it a step at a time, takes the
rectangle again after each step, and joins the screens with the toolkit's stitcher (`gt:image`, `stitch_begin`,
`stitch_add`, `stitch_end`). The picture goes to the run of the region's workflow, as a region's picture does.

The tray's check item, the command palette and `cliche --scrolling-capture` start it. The same three, or Escape where
the system lets a program take Escape for a while (Windows), cancel it. A cancelled run keeps nothing.

## Three threads' parts, one state machine

`Scroll_Run` (`src/scrolling_capture.odin`) is the run's state machine: one union, one transition procedure
(`scroll_step`), tested without a desktop (`src/scrolling_capture_test.odin`). Each transition gives one act for the
app to do:

    Idle -(start, wheel can turn)-> Choosing -(rectangle)-> Capturing -(frame Added)-> Wheeling -(turned)-> Capturing
    Idle -(start, wheel cannot turn)-> Idle: act Unavailable
    Choosing -(cancel)-> Idle
    Capturing -(Same, Full, limit, Refused, or No_Overlap again)-> Ending (Keep)
    Capturing -(No_Overlap, first time, step > 1)-> Wheeling: back up by the difference, then a smaller step
    Capturing | Wheeling -(cancel)-> Ending (Drop)
    Capturing -(capture failed)-> Ending (Drop, Failed)
    Wheeling -(wheel refused)-> Ending (Drop, Unavailable) before a second screen, else Ending (Keep)
    Ending -(the worker's end)-> Idle

The acts are run where each must run:

- **Choose**: the region's overlay, on the interface thread, as a recording's region is chosen (`Region_Use.Scroll`).
- **Capture**: `Job_Scroll_Frame` on the worker: the rectangle cut from the desktop (`grab_rect`, the last region's
  call), settled, then added to the stitcher, which the worker holds.
- **Wheel**: `platform.send_wheel` on the interface thread. The toolkit requires the window's own thread on X11, so the
  one path takes that thread everywhere. It is input injection that returns at once (`SendInput`, an XTEST request),
  not a wait.
- **Keep** / **Drop**: `Job_Scroll_End` on the worker: the stitched picture handed back, or freed.

Refused: the whole loop on a thread of its own with the wheel and the capture as procedures. X11 needs the wheel on
the window's thread, and the worker owns the capture session: such a thread would have to post to both at each step
anyway. The ping-pong between the worker and the interface thread is that loop, with no third thread.

Refused: a new `Source` (and `Trigger`) for the scrolling capture. Every array over `Source` (the Capture node, the
Condition node, the file name's `%s`) would gain an entry that no workflow can choose. The picture is a region's:
its source is `.Region`, and the region's workflow runs it. A trigger of its own, with its own workflow, can come later
if a person asks for one.

## The worker's settle

After a wheel step the page moves, maybe smoothly, and repaints. A frame taken too early shows the old screen, which the
stitcher reads as `.Same`, the end of the page. So a frame is taken in two phases, bounded by `capture.scroll_settle`:

1. Until a capture differs from the last frame taken: the page moved.
2. Until two captures in a row are equal: the page stopped moving.

At the bound, the newest capture is used. If the page never moved, that capture equals the last frame and the
stitcher says `.Same`: the end costs one bound. The first frame skips phase 1; it first waits `SCROLL_OVERLAY_GONE_MS`
for the overlay's windows to leave the screen, since the overlay shows a picture of the same page.

Between two captures the worker waits `SCROLL_PACE_MS`, about one display frame: a capture faster than the screen
repaints only spins. The pace is not the condition: the comparisons are.

## The step and its retry

The step is `capture.scroll_notches` wheel notches (3). A program scrolls an unknown height a notch. If a step moves
more than a screen minus `STITCH_MIN_OVERLAP` rows, the stitcher answers `.No_Overlap` and changes nothing. The run then
retries once: the wheel goes back by the difference to a step of half the notches (at least one), so the page stands
one smaller step after the last frame added, and the frame is taken again. The smaller step stays for the rest of the
run: the page showed that the larger one is too large. A second `.No_Overlap`, or one with a step of one notch, ends the
run with what was gathered.

## The pointer

The wheel goes to the window under the pointer. On Windows cliche moves the pointer to the middle of the rectangle
(`pointer_place`, `SetCursorPos`), so the person can let go of the mouse. The toolkit has no call that moves the
pointer, and on X11 cliche has none of its own: there, a notification asks the person to keep the pointer over the
page. Wayland lets no program turn the wheel of the seat (only the RemoteDesktop portal, which asks the person each
session): `send_wheel(w, 0)` is false there, and the start says that it is not available, before any overlay.

The pointer is not in the frames (`capture.set_cursor` stays off): it does not move with the page, and it would break
every overlap.

## Limits

- `capture.scroll_screens` (50): the most screens added. `STITCH_MAX_HEIGHT` bounds the picture's height as well
  (`.Full`).
- The rows match exactly. A thing that moves on its own inside the rectangle (a caret, an animation) breaks the
  overlap: the run ends with what it gathered.

## The scroll bar

A window's scroll bar does not scroll with the page, and its thumb moves down at each step: with it, no row of one
screen is a row of the next. So the stitcher leaves the rectangle's right columns out of the comparison
(`Stitch_Options.ignore_right`); they stay in the picture, each row with the bar as its frame showed it.

- `capture.scroll_bar_px` gives the width in logical pixels. 0 is automatic (`scroll_bar_auto_px`): on Windows the
  system's scroll bar width at 96 dpi (`GetSystemMetricsForDpi(SM_CXVSCROLL)`) plus `SCROLL_BAR_MARGIN_PX`; elsewhere
  `SCROLL_BAR_DEFAULT_PX` (20), as no system says how wide another program's bar is.
- The worker converts it to the frame's pixels with the first frame's scale (`scroll_ignore_columns`, rounded up), so
  the stitch begins at the first frame, not before. The automatic width is read there too: it is a system call.
- A rectangle with no scroll bar loses those columns from the comparison only. The page's other columns still decide
  the join.

Refused: finding the bar in the frames (columns that differ between two screens while the rest moved). It needs two
frames before the first join, and a page with a moving thing at its right edge would widen it.

## Subtle points

- A scrolling capture is one capture: while it runs, a trigger of any other capture is refused, as a second press is
  (`app_capture_start`). The auto capture's ticks are refused the same way.
- No result needs a generation: a new run starts only from Idle, which comes after the worker's end of the old one, and
  the worker answers in order.
- The rectangle stays on one output, as a recording's (`overlay_bounds_at`): the pointer's place and the wheel are
  for one window.
- Escape is taken from the whole desktop only while the run is in Capturing or Wheeling (`SCROLL_ESCAPE_HOTKEY` on the
  anchor), and given back at its end.
