# Architecture

## One resident process

`cliche` starts once per session and stays in the notification area (`src/app.odin`). A second start, such as
`cliche --region` bound to a key by the compositor, hands its command to the running one over gui_toolkit's instance
socket (`src/commands.odin`) and ends at once. A shortcut therefore costs no start-up.

At rest the process holds: a hidden anchor window (the tray icon, the notifications, the Windows hotkeys and the
clipboard are a window's), the worker's thread with the capture session already open, the thread that hears other
starts, and on Linux the thread of the global shortcuts (`gt:shortcuts`, the desktop portal). The
renderer is made at the first window that needs one, and that window is hidden, not closed, so it comes back at once.

## Threads

- **The interface's thread** reads the anchor's events, the commands of other starts, the tray and the worker's results,
  then draws the shown windows. It never captures, encodes, reads or writes a file.
- **The worker** (`src/worker.odin`) owns the capture session (`gt:capture`) and does everything slow: it reads the
  desktop, cuts a region, swaps the channels, encodes PNG, writes files. Its results are posted back. It is a `gt:tasks`
  pool of one thread that never grows: the session belongs to the thread that opened it, and the jobs run in order.
- **The chores** (`ui.chores()`, gt:tasks) run the rest: an editor's file read and decoded (PNG, JPEG, WebP, BMP:
  `image.decode`), its mosaics and blurred copies (one per size its shapes use), a picture pasted into it decoded, the
  system's file dialogs (`ui.file_dialog`; the editor's Save as with its suggested name, which needs the local time),
  the print dialog (`platform.print_image`), a file read for a pin, a file shown in its folder (`ui.open`).
- **The preferences' writer** (`config.User_Writer`) writes the preferences' file; the loop hands it the text once a
  turn, when they changed.
- **The log** (`gt:log`) writes `cliche.log` in the state folder; a crash writes a report beside it (`gt:crash`), which
  the next start announces.

## The capture flow

One state machine (`src/flow.odin`): `Idle -> Capturing -> Selecting (region, colour) -> Encoding -> Idle | Failed`. One
union, one transition procedure; a transition not in the table is refused, and the tests drive it without a window. The
picture is handed to a run of the capture's workflow, and the flow is Idle again: the next capture may start while the
run goes on.

The sources: a region (chosen on the frozen desktop), the screen under the pointer, the window in front, all the screens
(`capture.desktop`), the last region (the rectangle chosen last, cut from the desktop now: no overlay; with none yet, a
region), and the colour picker (the overlay with no rectangle: a click copies a pixel's colour, `src/color_pick.odin`,
and the flow ends with no picture). The workflow that will run gives its Capture node's delay and pointer: the worker
counts the delay down (`countdown_plan`: a notice each second, withdrawn just before the picture) and asks gt:capture
for the pointer (`capture.set_cursor`; Wayland and Windows draw it, the portal and X11 cannot).

## A region

On the trigger the worker reads the desktop (`capture.desktop`, every output in one picture) and the windows with their
rects. The interface then shows one fullscreen window (`src/overlay.odin`) that draws that frozen picture, dimmed outside
the selection. This works the same on every compositor: no layer surface, no transparency. The geometry of the selection
(drag, nudge, resize, the grips that move and resize it with the mouse, a double click, the framed window) is pure
(`src/geometry.odin`).

## Workflows: after a capture

What happens to a picture is a workflow: a graph of nodes linked port to port, each port of a kind (a picture, a text, an
address, a file, an action). Each trigger (region, screen, window, edit, qr, ocr: the shortcuts, the tray, the commands)
runs exactly one workflow. Two triggers capture nothing: Clipboard (`--upload-clipboard`) runs its workflow on what the
clipboard holds, Upload_File (`--upload-file`) on each file chosen in the system's dialog; the Capture node gives a
picture, a file or a text, each on its own output, and what hangs on the others is skipped. Recording is not a
workflow. The graph, its edits, its file and its run are the toolkit's `gt:flowgraph`; cliche gives its catalog and
does each node's work.

- **The model** (`src/workflow.odin`): `Workflows`, a `flowgraph.Graph_Set` whose entries are the workflows and whose
  labels are the names of the triggers that run each. flowgraph's edits keep a graph valid (no cycle, kinds that agree,
  one link into a port that takes one, one Capture node: its `max_count` and `min_count`). The default workflows are
  what cliche did before: Screenshot (copy and save), Edit then share (Annotate, then copy and save), Read a QR code and
  Read the text (copy the text, notify).
- **The catalog** (`src/workflow_nodes.odin`): `CATALOG`, a `flowgraph.Catalog` in `Node_Kind`'s order: each kind's
  title, icon, group, ports and parameters (Int, Float with its range and unit, Bool, Color, Choice, Text, Folder, List:
  the uploaders), where its work runs, whether it acts outside the picture (off in a preview), and `node_summary`, a
  summary of its parameters for the node's subtitle. Annotate has two action outputs, "done" and "cancelled", and Ask
  "yes" and "no"; each effect has an action input, "when", and an action output, "done", and Upload a "failed" too. A
  node whose "when" is linked waits for that action: the editor's Done or Cancel, an answer, another effect's end. An
  action output is the last of its node's outputs, so the links of a saved workflow keep their port numbers.
- **The engine** (`src/workflow_run.odin`): a `flowgraph.Run` and what cliche adds, pure, tested without a window. Each
  node is flowgraph's small state machine (`Waiting -> Running -> Done | Failed | Cancelled`, `Waiting -> Skipped`); a
  node runs when every node before it is decided and its linked actions fired; a failed, cancelled or skipped node skips
  what needs it; a Condition gives one of its two outputs. `run_tasks` finishes at once what the run decides itself
  (Capture, Condition, Annotate in a preview). Pictures are shared read only between branches (a counted value) and let
  go when no node will read them. `run_summary` makes the run's one notification.
- **The work** (`src/workflow_ops.odin`): what runs on the worker (`Job_Node`): the transformations (`gt:image`), the save
  (`src/save.odin`), the upload and the shortened address, a QR code read or made, the text, a file opened or deleted. A
  transformation makes a new picture; one that works in place works on a copy. The worker also makes what a run that is
  no capture's starts from (`Job_Run_Input`: the clipboard's picture decoded, a file looked at). What must run on the
  interface's thread (the clipboard, the history, a pin) and what waits for a person (Annotate: the editor's Done or
  Cancel; Ask: the Yes or No of a notification, `Questions` in `src/workflow_run.odin`) are `src/workflow_app.odin`'s,
  which also starts the runs (several may be in flight), reads the clipboard without waiting (`clipboard_request`, the
  order in `clipboard_next`), opens the files' dialog on a chore, and tells a run's end: a click on its notification
  opens its address, else its file.
- **The editors** (`src/editor.odin`): each Annotate opens its picture at once in an editor of its own (`app.editors`),
  any number open together. An editor holds the run and node its picture is for (`Editor.ask`): its Done, its Cancel or
  its close ends that node, and that node only. Its id (`Editor.id`) goes with its Ctrl+C and Ctrl+S to the worker and
  back; a result whose editor has closed is said where cliche says things. A closed editor is freed, but for one kept
  hidden for the next picture and the renderer's own window. Its undo is a `gt:undo` stack of the shapes and the crop.
  What it does with its picture besides Done (`src/editor_output.odin`) starts from the flattened picture: Save as (the
  system's dialog on the chores, then `Job_Save_As`: one state machine, `Editor_Save_As`), Upload (`Job_Upload` with
  the default host; the address to the clipboard and the history), Print (`platform.print_image` on the chores). A
  picture file dropped on an editor opens in an editor of its own, after the frame.
- **The pins** (`src/pin.odin`): a picture kept over every other window, each a window of its own (`app.pins`), from
  the editor (Ctrl+T) or a file (`pin_picture`). It is gt:host's overlay (a layer surface on Wayland, a topmost window
  elsewhere) whose input region is the picture alone; where the compositor has no layer shell, a normal window. Its
  geometry is pure (`pin_place_first`, `pin_zoom_at`, `pin_drag_to`), its drag one state machine (`Pin_Gesture`).
- **The store** (`src/workflow_store.odin`): `<config dir>/cliche/workflows.json`, `flowgraph.set_text` and `set_parse`
  under cliche's keys ("workflows", "triggers"), read on the worker at the start, written on the worker after each change
  (at the end of a gesture). A broken file is kept aside as `workflows.json.broken`, and the defaults take its place.
- **The mode** (`src/workflow_view.odin`, `src/workflow_inspector.odin`): the main window's third mode. The list of
  workflows, the graph (`ui.node_graph` on `ui.flow_nodes_make`'s nodes: the program owns the model, applies the widget's
  events, keeps one step of undo per change in a `gt:undo` stack), the add palette (`ui.flow_palette`) and the inspector
  (`ui.node_inspector`, drawn from the parameters' schema). The graph's nodes are made again when the model or the last
  run's marks change, not at each frame. "Run on the last capture" decodes the newest picture of the history on the
  worker and runs the workflow with its effects off; each node then shows its state and a thumbnail of its picture.

## Shortcuts

`src/shortcuts.odin` binds one global shortcut per kind of capture through `gt:shortcuts`: on Linux the desktop portal's
GlobalShortcuts (the system may give other keys than the ones asked: the settings show which), on Windows
RegisterHotKey. The commands (`cliche --region`) stay for a compositor's own bindings.

A workflow may also have keys of its own: its Capture node's `shortcut` (a `flowgraph` Hotkey parameter, recorded in the
inspector) and `source`. They are bound as `workflow-<id>`; a press captures that source and runs that workflow
(`Capture_Target`). The set is bound again when the workflows' version changes and a workflow's keys, its name or the
list of them did. The settings' Shortcuts page lists each workflow's keys under the fixed ones.

## Settings

`src/settings.odin` is the registry (one `config.Def` per preference, a group per page: the first segment of its name);
the look, the text, scrolling, input, the delays, rendering and the session are the toolkit's standard preferences
(`prefs_page.standard_register`, gui_toolkit docs/settings.md), applied to each window's interface as they change
(`app_standard_follow`: a `prefs_page.standard_watch` per open window, ended before the window closes). The settings are
a mode of the main window (`src/history_view.odin`), as the workflows are: `src/settings_view.odin` builds them with
`gt:prefs_page` in place of the history, with its back bar, the theme cards and the user's own themes file
(`prefs_page.Themes_File`), the shortcuts' lines the toolkit draws, the settings file, export and import. What is slow
(opening a folder, the desktop files of `src/integration.odin`) runs on the worker; the folder dialog on the chores
(`ui.file_dialog`). `clichetool shots` draws each page offscreen (`src/shots.odin`).

## Licence

`src/licence/product.odin` describes cliche's licence for `gt:licence` (gui_toolkit docs/licence.md); `src/licence.odin`
gives it to the toolkit's Licence page of the settings (`prefs_page.Licence`: its store, read and changed only in
tasks, and its page, worded the same in every program). `clichetool
licence` and `clichetool paddle` are the toolkit's commands; `clichetool site build` adds the shop's pages (pricing,
thanks, terms, refunds, privacy, imprint), whose buttons say "Coming soon" until the shop is set up. `secrets/` and
`.sops.yaml` hold the maintainer's encrypted keys once made.

## Recording

A recording is a flow of its own (`src/record.odin`: one union, one transition procedure, tested without a window): its
region is chosen on the frozen desktop as a screenshot's, then a third thread, the recorder, which exists only while a
recording runs, reads a stream of the screen (`capture.stream_*`), encodes it (`gt:h264` and `gt:mux` for an MP4,
`gt:gif` for a GIF) into `<name>.part`, and renames it at the end. Between the region and the recorder, the flow waits
in Ready: `src/record_overlay.odin` shows an overlay window (`host.Open.overlay`: a layer surface on Wayland) with a frame
around the region, outside it, and a bar of buttons, the only part that takes the pointer (`platform.set_input_region`).
Record starts the recorder; Cancel while recording discards its file. `src/record_app.odin` ties it to the commands,
the tray (a red icon and its own menu meanwhile) and the notification.

## Upload and text

A workflow's Upload step sends a picture (as PNG), a file or a text to the uploader chosen (`src/uploader.odin`: ShareX's
`.sxcu` files and their syntax), on the worker; a Copy text step after it puts its address on the clipboard. Shorten URL
sends an address to a URL shortener (is.gd and v.gd built in, or a `.sxcu` one: `{input}`). Read text reads the text of a
picture with `gt:ocr`, Read QR code a QR code with `gt:qr`, Make QR code makes one with `gt:qr`, all on the worker.

The history (`src/history_view.odin`) combines two pictures or more of its selection into one (`gt:image` `combine`, on
the worker), opens an entry's address, and filters by date; the tray's Recent submenu shows its last five entries.
