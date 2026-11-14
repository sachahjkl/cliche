# cliche

A screenshot and screen-recording tool for Linux (Wayland first) and Windows, in Odin, on the `ext/gui_toolkit` submodule
(collection `gt`). In the spirit of ShareX: capture, then a workflow the user edits as a graph (transforms, branches,
conditions, the editor as a step, clipboard, file, upload, QR, OCR).

Read first: [README.md](README.md), [docs/architecture.md](docs/architecture.md).

## Build and test

Every step is a command of `tools/clichetool` (`help` lists them):

    odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -keep-executable -- <command>

- `build [release]` builds `build/cliche` (`build.sh` / `build.bat` are shortcuts). Without `release`: no optimisation,
  the fastest build, for iterating.
- `check`: `odin check -vet` for this system and for the other one, the changelog's fragments, the tests, a release build.
- `changelog new <type> <text>` writes a fragment.
- Linux: `nix develop` first (`flake.nix`). `nix build` builds the package.

## Rules

- What another program could use goes in gui_toolkit, generic, with its docs, tests and changelog fragment (the capture
  is `gt:capture`, the GIF encoder `gt:gif`); cliche then points to the toolkit's new tag.
- Nothing slow on the interface's thread: capture, encoding, disk and network run on the worker (`src/worker.odin`), and
  their results are posted back.
- The capture flow is one state machine (`src/flow.odin`): one union, one transition procedure, tested without a window.
- A workflow's run is one state machine too (`src/workflow_run.odin`), pure and tested without a window; picture work
  runs on the worker (`src/workflow_ops.odin`), the clipboard, notifications and the editor on the interface's thread
  (`src/workflow_app.odin`). The node catalog (`src/workflow_nodes.odin`) describes each kind's ports and parameters:
  the inspector and the node's summary need no code per kind.
- Platform code goes in files with a system suffix (`*_linux.odin`, `*_windows.odin`, `*_other.odin`).
- A preference is a `config.Def` in `src/settings.odin`, with its control on a page of the settings.
- What changed is one fragment in `changelog.d/` (its README), never an edit of `CHANGELOG.md`.
- Tests never touch the person's desktop or clipboard: a test of a window runs offscreen.
- Automation is a command of `tools/clichetool`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.

## Roadmap

- `ROADMAP.md`, beside `CHANGELOG.md`, holds cliche's planned work: `# Roadmap`, then `## Now`, `## Next` and `## Later`,
  each a list. Each entry starts with a bold summary, then one or two sentences on what it gives the user. No dates, no
  front matter.
- When a work is done, remove its entry in the same commit as its changelog fragment.
- Work that touches several programs goes in the roadmap of gui_toolkit.
- `clichetool check` checks its format with the changelog's.

## Intent

This project follows <https://srcmd.org>, with the Markdown in `src/md`. Read `src/md/README.md` first.

- Change the intent first, then derive the code and the tests. A change of design changes its intent file in the same
  commit.
- Keep there what the code does not show: the purpose, the decisions, the refused alternatives, the subtle points.
- `src/md/README.md` lists every other file of the folder in its `## File Index`.
