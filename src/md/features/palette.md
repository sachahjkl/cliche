# cliche's command palettes

cliche's palettes are the toolkit's one palette (gui_toolkit's `src/md/features/palette.md`, `docs/palette.md`), fed
by sources. Code: `src/palette.odin` (cliche's sources), `history_palette_feed` and `history_palette_chosen` in
`src/history_view.odin`, `editor_palette_feed` in `src/editor.odin`, `workflow_add_feed` in `src/workflow_view.odin`.

## Purpose

- **Homogeneity first.** The same look, keys, prefixes and Recent as in the other programs of the toolkit. cliche's
  three palettes decoded a chosen index by ranges of a concatenated table (the actions, the settings, the views'
  moves); the toolkit's sources replace that code.
- **The things of cliche are reached from the palette**: a capture by its name, a workflow by its name.

## The palettes

| Window | Sources |
|---|---|
| The main window (history, settings, workflows) | `>` its commands (the history's actions, the settings' actions, the Workflows mode's while it is shown) and the moves of its views; `@` the captures; `#` the workflows; `:` the settings |
| Each editor | `>` its actions (every one but Nudge, whose keys are the arrows) and the moves of its views |
| The workflows' add palette | the kinds of step: the toolkit's chooser (`ui.flow_palette`), one source with no prefix (no hint row) |

## Decisions

- **`@` the captures: go to one.** Choosing a capture shows the history, its search and its filters cleared (they may
  hide it), the capture selected alone and brought into view. Newest first; the group is its kind.
- **`#` the workflows: choose one, the one shown marked.** Choosing one shows it in the Workflows mode.
- **Both are in the plain search too**, as the toolkit's example sources are (sessions, tabs): homogeneity. The toolkit
  puts a program's own items a few points behind the commands at an equal score.
- **The commands source gets a version, never a compare.** What can act is a set (the history's actions and the
  settings' actions; the editor's actions); a new set raises the version. Two sets compared at each build, no pass over
  the table or over `disabled`. The history's set is kept by `history_enabled` on the selection's version (its
  `Item_Selection.version`), the cursor and the history's version: no pass over the selection at a build. The
  editor's is a fixed number of checks of its model (its selection is its shapes', not an `Item_Selection`). The
  Workflows mode's commands are the end of one table, given longer while the mode shows: the table's length is part of
  what the palette compares.
- **The settings source is added once.** It reads its page options when it reads (`settings_options`, a procedure of
  the app), so a new updater or licence needs no new add.
- **The palette's command is the toolkit's** (`ui.palette_command`, Ctrl+K and Ctrl+Shift+P, read by
  `ui.palette_keys`). The sheets list it themselves: the actions tables have no line of it. The toolbar's buttons
  toggle the palette (`ui.palette_toggle`), their tip the toolkit's command's.
- **Two usage memories**: the main window's (`palette_choices.txt`) and the editors' (`editor_palette_choices.txt`), in
  the state folder. One memory per path, shared by the toolkit: the editors open together share theirs.
- **Each command has an id** (`ui.Command.id`, the enum's name in lower case, written out): the memory's key and the
  key of the person's keys and aliases (gui_toolkit's `src/md/features/keymap.md`). The memory was keyed by the English
  label before: it was lost once, at the change. An id never follows a label's wording.
- **One id in two tables is one command.** The editor shares `copy`, `pin`, `upload`, `select_all`, `shortcuts` and
  `close` with the history, and `undo` and `redo` with the Workflows mode: the same act, so a key the person sets for
  it acts in both. Two acts of one name take two ids (the history's Preview is `preview`, the Workflows mode's Run on
  the last capture `workflow_preview`). `the_ids_the_editor_shares` lists the shared ids: a new one is a decision.
- **One `ui.Keymap` for the process** (`App.keymap`): every window reads it (`app_standard_follow`), and every table's
  ids are known at the start, before a window reads a key. Each window's `standard_watch` reads `keys.custom` and
  `keys.aliases` into it and writes the person's changes back, whichever windows have closed since.

- **Each palette's choice is taken before its window's content** (`ui.palette_chosen` after the keys, before the
  page): the run mode's writes and a command chosen show in the same frame as the palette. The main window takes its
  palette's there and the add palette's at the top of the Workflows mode (`workflow_add_take`); the editor after its
  window's keys. A command may change the mode: the main window reads its mode again after the choice.
- **Go to: every element that runs a command states its act name** (`ui.act_command`; a toolbar tool given its
  `command` states it itself, `tool-bars.md`). The settings' footer buttons (Choose a folder, Open the folder, which is
  the history's `open_folder`, the uploaders, the system's shortcuts), the Workflows mode's Back, New workflow and
  Rename, the lines of the history's menu and of the editor's menus (the zoom's Fit and 100 %). Shift+Enter on the
  command goes there. A button of no command (Duplicate, Delete a workflow, a shortcut's Copy) states none.
- **Rename the workflow is a command with an argument** (`workflow_rename`, `WORKFLOW_RENAME_ARGUMENTS`): its form in
  the palette asks the new name, `Palette_Choice.arguments` gives it to `workflow_action`. The settings source installs
  the forms runner. The form's field starts empty: a `config.Def`'s default is a constant, not the workflow's name. The
  list's Rename button, a double click and the command with no value (a key) type the name in the list: the same
  command, the field in place, beside the name it replaces.
- **Kept as dialogs**: the editor's size and margins (a width and a height that keep a ratio, four sides and a
  colour: several values that follow each other), the questions before files or a workflow are deleted (a
  confirmation, with the names that go), the preview (a picture). cliche asks no capture's name and no delay in a
  dialog: a capture's name comes from the pattern of the settings, a delay is a parameter of a workflow's Capture step,
  set in its inspector.

## Subtle points

- A source's `poll` follows its data: the captures the history's version, the workflows theirs. The add palette's
  source is given the graph shown, the port a link was dropped from and the workflows' version at each build of the
  mode; it reads the kinds again when one changed.
- A palette is destroyed before its window's State: the editor's in `editor_destroy`, the main window's in
  `history_window_free`. The sources are added when the palette does not have them (`ui.palette_has`), so the
  screenshots, which open the window again, add them to the next palette.
