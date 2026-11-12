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
  desktop, cuts a region, swaps the channels, encodes PNG, writes files. Its results are posted back.

## The capture flow

One state machine (`src/flow.odin`): `Idle -> Capturing -> Selecting (region only) -> Encoding -> Idle | Failed`. One
union, one transition procedure; a transition not in the table is refused, and the tests drive it without a window. The
picture is handed to a run of the capture's workflow, and the flow is Idle again: the next capture may start while the
run goes on.

## A region

On the trigger the worker reads the desktop (`capture.desktop`, every output in one picture) and the windows with their
rects. The interface then shows one fullscreen window (`src/overlay.odin`) that draws that frozen picture, dimmed outside
the selection. This works the same on every compositor: no layer surface, no transparency. The geometry of the selection
(drag, nudge, resize, the framed window) is pure (`src/geometry.odin`).

## Workflows: after a capture

What happens to a picture is a workflow: a graph of nodes linked port to port, each port of a kind (a picture, a text, an
address, a file). Each trigger (region, screen, window, edit, qr, ocr: the shortcuts, the tray, the commands) runs exactly
one workflow. Recording is not a workflow.

- **The model** (`src/workflow.odin`): `Workflows`, `Workflow`, `Workflow_Node`, `Workflow_Link`, and the edits that keep
  a graph valid (no cycle, kinds that agree, one link into a port that takes one, one Capture node), pure. The default
  workflows are what cliche did before: Screenshot (copy and save), Edit then share (Annotate, then copy and save), Read
  a QR code and Read the text (copy the text, notify).
- **The catalog** (`src/workflow_nodes.odin`): each kind's title, icon, group, ports and parameters (`Param_Def`, a generic
  schema: Int, Float with its range and unit, Bool, Color, Choice, Text, Folder, Uploader), where its work runs, whether
  it acts outside the picture (off in a preview), and a summary of its parameters for the node's subtitle.
- **The engine** (`src/workflow_run.odin`): a run of a graph, pure, tested without a window. Each node is a small state
  machine (`Idle -> Running | Waiting -> Done | Failed`, `Idle -> Skipped`, `node_step`); a node runs when every node
  before it is decided; a failed or skipped node skips what follows it; a Condition gives one of its two outputs. Pictures
  are shared read only between branches (a reference count on the interface's thread) and let go when no node will read
  them. `run_summary` makes the run's one notification.
- **The work** (`src/workflow_ops.odin`): what runs on the worker (`Job_Node`): the transformations (`gt:image`), the save
  (`src/save.odin`), the upload, the QR code, the text. A transformation makes a new picture; one that works in place
  works on a copy. What must run on the interface's thread (the clipboard, the history) and the editor (Annotate: the run
  waits for Done; a close stops that branch) are `src/workflow_app.odin`'s, which also starts the runs (several may be
  in flight) and tells their end.
- **The store** (`src/workflow_store.odin`): `<config dir>/cliche/workflows.json`, read on the worker at the start, written
  on the worker after each change (at the end of a gesture). A broken file is kept aside as `workflows.json.broken`, and
  the defaults take its place.
- **The mode** (`src/workflow_view.odin`, `src/workflow_inspector.odin`): the main window's third mode. The list of
  workflows, the graph (`ui.node_graph`: the program owns the model, applies the widget's events, keeps one step of undo
  per change), and the inspector drawn from the parameters' schema. The graph's nodes are made again when the model or
  the last run's marks change, not at each frame. "Run on the last capture" decodes the newest picture of the history
  on the worker and runs the workflow with its effects off; each node then shows its state and a thumbnail of its
  picture.

## Shortcuts

`src/shortcuts.odin` binds one global shortcut per kind of capture through `gt:shortcuts`: on Linux the desktop portal's
GlobalShortcuts (the system may give other keys than the ones asked: the settings show which), on Windows
RegisterHotKey. The commands (`cliche --region`) stay for a compositor's own bindings.

## Settings

`src/settings.odin` is the registry (one `config.Def` per preference, a category per page); the appearance and session
preferences are the toolkit's standard ones (`prefs_page.standard_register`). The settings are a mode of the main
window (`src/history_view.odin`), as the workflows are: `src/settings_view.odin` builds them with `gt:prefs_page` in place of the history, with
its back bar, the theme cards and the shortcuts' lines the toolkit draws. What is slow (the folder dialog, opening a folder, the desktop files of
`src/integration.odin`) runs on the worker. `clichetool shots` draws each page offscreen (`src/shots.odin`).

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

A workflow's Upload step sends the picture to the uploader chosen (`src/uploader.odin`: ShareX's `.sxcu` files and their
syntax), on the worker; a Copy text step after it puts its address on the clipboard. Read text reads the text of a picture
with `gt:ocr`, Read QR code a QR code with `gt:qr`, both on the worker.
