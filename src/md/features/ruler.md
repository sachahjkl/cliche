# The ruler

The frozen desktop, a line drawn on it, its length in pixels and its angle beside it. Nothing is captured or copied.
`cliche --ruler`, the tray, the palette and its shortcut (`shortcut.ruler`, no keys by default) start it.

## A source, as the colour picker is

The ruler is `Source.Ruler`: the worker reads the desktop as for a region, the flow goes to Selecting, and the overlay
shows it in its third mode (`Overlay_Mode`: Region, Picker, Ruler). The flow accepts neither a confirm nor a pick in
that state: Flow_Cancelled (Escape, a right click, a close) is its only way out. So no picture reaches a workflow, and
no other capture starts while it is shown.

Refused: a flag beside `picker` in the overlay. Two flags make four states for three modes; the enum says which input
and which drawing apply.

## The measure

- The points are the desktop's logical pixels, as the region's size label is. On a scaled output the length reads as a
  region drawn over the same span would say, not in the picture's physical pixels.
- The angle reads as a protractor: 0 to the right, 90 up, in (-180, 180]. The screen's y goes down, so the measure
  turns it.
- The words also give the width and the height the line spans, for a quick box size.
- Shift holds the line to a multiple of 45°, its length kept.
- A new drag replaces the line. Escape ends the ruler at once, line or not: there is nothing to give up but the ruler.

The line is drawn light on a dark edge, so it reads on any picture; the words sit beside its middle, on its upper side,
kept inside the window. The overlay is not dimmed: the screen is measured as it is.

The measure, the snap and the drag are pure (`src/ruler.odin`), tested without a window.
