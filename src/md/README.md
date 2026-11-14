# cliche: intent

cliche takes a screenshot or a screen recording, then runs it through a workflow that the person draws as a graph. This
folder records why the code has its shape: the purpose, the decisions, the refused alternatives. It is not the user's
documentation (`README.md` at the root) and not the map of the code (`docs/architecture.md`).

## Overview

- One process lives in the notification area. One interface thread draws every window. A worker does the capture, the
  encoding, the disk and the network, and posts its results back.
- A capture is one state machine (`src/flow.odin`). It ends when the picture goes to a run of its workflow.
- A run is a `flowgraph.Run` of the toolkit (`src/workflow_run.odin`). Each node waits for its inputs and for its action
  input ("when"). An action output ("done", "cancelled", "failed", "yes", "no") fires when its node ends that way.
- Each picture that goes to the editor opens an editor window of its own. Done or Cancel ends that run's branch only.

## Subtleties

- Nothing slow runs on the interface thread: not a `stat`, not a small read.
- What another program can use goes to the toolkit (`ext/gui_toolkit`), generic. cliche keeps its own words and layout.
- A new port of a node goes after the old ones. The links of a saved workflow name ports by their index.

## File Index

- [features/editor-bars.md](features/editor-bars.md): the editor's two bars, tools above and actions under; why nothing
  folds away
- [features/history-selection.md](features/history-selection.md): the history's selection, the toolkit's, one for the
  grid and the list; what acts on several entries, what on the cursor's
- [features/palette.md](features/palette.md): the command palettes, the toolkit's, fed by cliche's sources (`@` the
  captures, `#` the workflows, the add palette as a chooser)
- [features/title-bar.md](features/title-bar.md): cliche's own title bar on its normal windows, the system's as a
  setting; which windows have one
- [features/views.md](features/views.md): the dialogs and the preview as gui_toolkit's views; several windows owning
  views, an editor's instances, where each view opens
