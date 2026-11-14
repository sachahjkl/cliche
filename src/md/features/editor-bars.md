# The editor's two bars

The editor has a bar above the picture and a bar under it. Each is the toolkit's tool bar in its Wrap mode
(`ui.toolbar(id, {overflow = .Wrap})`; the toolkit's `src/md/features/toolbar.md`). Code: `editor_tools_bar` and
`editor_actions_bar` in `src/editor.odin`.

## Purpose

- **Above: what draws.** The tools, the Insert and Picture menus, then the properties of the tool or of the selection
  (colours, fill, width, heads, dashes, corners, text, steps, magnifier, blur, pixels, shadow).
- **Under: what is done with the picture.** The zoom, undo and redo, copy, save, upload, pin, then Cancel and Done at
  the right end.

The split follows what the hand does. A person draws with the bar above, many times per picture. They end with the bar
under, once per picture. ShareX's editor has the same split.

## Decisions

- **Nothing is hidden.** A window too narrow for a bar wraps it onto more lines (the Wrap mode). The canvas takes what
  is left. A tool that the person cannot see is a tool that they do not have.
- **Refused: a bar that folds into a "…" panel** (`ui.toolbar`'s old fold, cliche 0.3.0 to 0.5.0). The person had to
  open the panel to find a tool, and the tools that it hid changed with the width of the window. The person refused
  it. The toolkit's Fold mode is not used here for the same reason.
- **Refused: bars built by hand** (`ui.flow` in a row, cliche's own separators and end buttons). The toolkit's tool bar
  does the same in both of its modes, and other programs use it: one bar, one look.
- **The bar's parts.** Above: the group "tools" (each tool a `toolbar_tool` of its command, held down when it is the
  tool in use; the Insert and Picture tools, which open their menus), then the groups "colours", "fill" and "style", a
  line before each.
  Under: the group "zoom", the group "picture" (undo, redo, copy, save, upload, pin), then the pinned group "end".
- **A property stays in one piece.** Each property is one `toolbar_control`: the colours and their "another colour"
  disc, or a label and its slider, go to the next line together, never split. A group goes to the next line whole; a
  group wider than a line wraps its properties, each whole. Bold is a tool (`on` while the text is bold).
- **Cancel and Done never wrap away from each other.** They are the pinned group at the end of the bar under. In a
  narrow window the actions wrap before them.
- **The bar under has no separate zoom bar.** The zoom is the first item of the bar under, as in ShareX.

## Subtle points

- The colour popover anchors on the disc that opened it (`ed.color_anchor`, the disc's rect, built in its control).
  When the bar wraps, the disc moves, and the popover follows on the next frame.
- The Insert, Picture and zoom buttons are tools with a `menu`: each opens its menu under itself and is lit while it is
  open. The zoom tool's words are the zoom in percent.
- The Insert, Picture and zoom menus are built outside the bars (`editor_menus`, `editor_zoom_menu`). A menu that
  opened from a button stays open while the bar wraps under it.
- The spacing between the tools, the controls and the groups is the toolkit's, as in every bar. cliche adds none
  inside the bars; the colours' own gaps between their swatches are the control's.
