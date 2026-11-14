# The editor's two bars

The editor has a bar above the picture and a bar under it. Code: `editor_tools_bar` and `editor_actions_bar` in
`src/editor.odin`.

## Purpose

- **Above: what draws.** The tools, the Insert and Picture menus, then the properties of the tool or of the selection
  (colours, fill, width, heads, dashes, corners, text, steps, magnifier, blur, pixels, shadow).
- **Under: what is done with the picture.** The zoom, undo and redo, copy, save, upload, pin, then Cancel and Done at
  the right end.

The split follows what the hand does. A person draws with the bar above, many times per picture. They end with the bar
under, once per picture. ShareX's editor has the same split.

## Decisions

- **Nothing is hidden.** A window too narrow for a bar wraps it onto more lines (`ui.flow`). The canvas takes what is
  left. A tool that the person cannot see is a tool that they do not have.
- **Refused: a bar that folds into a "…" panel** (`ui.toolbar`, cliche 0.3.0 to 0.5.0). The person had to open the panel
  to find a tool, and the tools that it hid changed with the width of the window. The person refused it.
- **A property stays in one piece.** Each property is one box in the flow: the colours and their "another colour" disc,
  or a label and its slider, go to the next line together, never split.
- **Cancel and Done never wrap away from each other.** They are one box at the end of the bar under. In a narrow window
  the actions wrap before them.
- **The bar under has no separate zoom bar.** The zoom is the first item of the bar under, as in ShareX.

## Subtle points

- The colour popover anchors on the disc that opened it (`ed.color_anchor`). When the bar wraps, the disc moves, and
  the popover follows on the next frame.
- The Insert, Picture and zoom menus are built outside the bars (`editor_menus`, `editor_zoom_menu`). A menu that
  opened from a button stays open while the bar wraps under it.
