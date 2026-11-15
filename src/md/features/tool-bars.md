# cliche's tool bars

Every row of tools in cliche is the toolkit's tool bar (`ui.toolbar`; the toolkit's `src/md/features/toolbar.md`). A
row built by hand (a `ui.row` of buttons and segmented controls) runs past the window's edge when the window is narrow,
and its last tools are cut: the history's "Grid | List" was. The toolkit's bar never does.

| Bar | Mode | Why |
|---|---|---|
| The editor's two bars | `.Wrap` | nothing hidden while a picture is edited (`editor-bars.md`) |
| The history's filters and buttons | `.Fold` | one line under the search; what does not fit goes into the "…" menu |
| The workflows' bar | `.Fold` | one line beside the title; the palette pinned at its end |

## Decisions

- **The history's choices are controls.** The filter by kind, the thumbnails' size and the view are `toolbar_control`s
  holding their `ui.segmented`: folded, each is a row of the "…" menu with its label at the left and the segmented
  control at the right. Refused: each choice as a tool of its own (one row per choice, the current one checked): in
  the bar the choices would be separate buttons, not one segmented control. The toolkit has no item that is a
  segmented control in the bar and checked rows in the menu.
- **What folds first** (the lowest priority): the save folder, the thumbnails' size, the view, the window's buttons;
  the filter by kind last.
- **Beside the search, the bar is as wide as its tools at most, and never wider than what the search leaves**: an
  estimate too small folds a tool, never runs past the edge. Too narrow for the search's placeholder and the tools, the
  bar goes to a line of its own, as wide as the window.
- **The workflows' buttons are the commands' tools** (`WORKFLOW_ACTIONS`): their tips and their menu rows say their
  keys as everywhere.
