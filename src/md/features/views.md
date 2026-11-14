# Views in cliche

cliche's dialogs and panes are gui_toolkit's views (the toolkit's `src/md/features/views.md`, its `docs/views.md`).
The code: `src/views.odin`, and each window's file for its own views.

## Purpose

The person chooses where a dialog or a pane shows: as a dialog, floating inside its window, in a window of its own, or
docked. cliche keeps that choice per view, and which views were open, in `<state>/views.txt`.

| View | Window | Home | Instance |
|---|---|---|---|
| `preview` | the history | Panel, right of the space `history` | none |
| `history_delete`, `workflow_delete` (questions) | the history | Dialog | none |
| the palette, the add palette, the sheet, `setup` | the history | Dialog | the toolkit's |
| `editor_size` | each editor | Dialog | the editor's name |
| `editor_drop` (the question before a close) | each editor | Dialog | the editor's name |
| the palette, the sheet | each editor | Dialog | the toolkit's |

## Decisions

- **One `ui.Views` for the program.** Every window's State gets it (`views_window`), the overlays and the pins too,
  although they open no view: `ui.views()` outside a build is then always the program's, whichever window was built
  last.
- **The backend of the views' windows follows the build.** A `Views` has one backend, and `host.view_windows(h)` steps
  and frames the windows of the views that `h` owns, after `h`'s frame. Each window that owns views sets it to its own
  host at the top of its build (`views_owner_build`). The step after that frame uses it. Refused: one backend on the
  history window: an editor's view in a window of its own would be stepped after the editor's frame but framed only in
  the history's, which is often hidden.
- **An editor's views are instances named by the editor** (`Editor.name`, `editor-<id>`). Two editors open the size
  dialog side by side, each with its own answer. Their memory is shared: the place that the person chose for one
  editor's size dialog is the place of the next one's.
- **A view opens in the build of its window.** A close asked by the system (the editor's title bar) or a command from
  another process (`cliche --setup`) comes outside a build. It sets a flag (`Editor.drop_due`,
  `History_Window.setup_due`), and the window's next build opens the view. Else the owner would be the State used last,
  perhaps another window's.
- **The preview's home is a dock space around the grid or the list** (`history`), not the window's frame. That space is
  built only in the history's mode, so the preview steps aside in the settings and the workflows, open still. Docked at
  the frame's edge by the person, it shows in every mode: their choice.
- **The window's keys wait while one of its views that takes keys is open**, in any presentation: its palettes, its
  sheet, a question, the size dialog, the setup. This is the rule of the dialogs that these views were. The preview is
  not one: it leaves the keys to the page.
- **Each palette lists the moves of its own window's views.** An editor's palette keeps the moves of its instance. The
  history's leaves out the editors' views, the palettes (open while they list) and the sheets (the toolkit does not
  name a sheet's window: its header moves it).
- **A view that asks about a window's content closes with it.** The editor's views close when the editor is kept for
  another picture. The history's palettes and questions close when the window hides; the preview stays. The workflows'
  add palette and question close when the mode is left.

## Subtle points

- An answer is read one build after the view ends. A question may float beside its content while that content
  changes: the delete checks that each file is still there, the size dialog applies to the picture as it is then.
- The size dialog gives the keyboard to its first field in its first build, unseen as it is: what the person types
  before it shows goes in. The key of the field is computed as `ui.number` makes it (its row's key, then `###value`).
- The editor builds no `views_frame`: it has no pane. Its views float, open in a window, or show as dialogs; the dock
  acts are absent there.
