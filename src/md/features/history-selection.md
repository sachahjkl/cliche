# The history's selection

The history window selects its captures as a file manager does: the toolkit's `ui.Item_Selection`, multi (the
toolkit's `src/md/features/selection.md`). Code: `src/history_view.odin` (`history_selection`, `history_rows`,
`history_cursor`, `history_rows_settle`, `history_grid_target`).

## Decisions

- **One model for the grid and the list.** It is the list's table's (`Table.vl.selection`). The grid calls the same
  procedures with its rows (`item_selection_click`, `item_selection_context`, `item_selection_move`). Refused: cliche's
  own `History_Selection` beside the table's marks, copied one into the other at each change: two models of one
  selection, and their rules differed (a range that only grew, the marks empty while one row was selected).
- **The grid's keys go by columns.** A key gives the cell the cursor goes to (`history_grid_target`: a line is the
  grid's columns), the model what its modifiers do: alone the cell alone, Shift the range from the anchor, Ctrl+Shift
  the range added, Ctrl the cursor alone. Ctrl+Space toggles the cursor's cell. The search keeps Left, Right, Home and
  End while it has the keyboard.
- **The acts on entries take every entry selected**, in the order shown: open, open the URL, show in the folder, copy
  the paths, the URLs, the texts, upload, combine, delete, remove. With none selected, the cursor's. **The acts on one
  picture take the cursor's**: the preview, copy the picture, edit, pin.
- **Escape follows the toolkit's rule**: several selected, the cursor's alone (`item_selection_escape`); then the
  search's Escape (it empties it); then the window's (it hides).

## Subtle points

- The rows are the view's: the grid's are the entries shown, the list's its table's ids (its order). The cursor is an
  index: when the rows change (a search, a filter, a sort, a removal, the other view), its entry is kept and found
  again in the new rows (`history_rows_settle`), where they are fresh: the grid's at once, the list's once its table is
  applied. Only when something is due: no pass over the rows at each frame.
- An entry selected from outside (a new combined picture, the tray's Recent) waits in `select_due` until it is in the
  rows.
