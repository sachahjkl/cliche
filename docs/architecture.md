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

One state machine (`src/flow.odin`): `Idle -> Capturing -> Selecting (region only) -> Encoding -> Done | Failed`. One
union, one transition procedure; a transition not in the table is refused, and the tests drive it without a window.

## A region

On the trigger the worker reads the desktop (`capture.desktop`, every output in one picture) and the windows with their
rects. The interface then shows one fullscreen window (`src/overlay.odin`) that draws that frozen picture, dimmed outside
the selection. This works the same on every compositor: no layer surface, no transparency. The geometry of the selection
(drag, nudge, resize, the framed window) is pure (`src/geometry.odin`).

## After a capture

A chain of actions (`src/actions.odin`): copy, save, upload; the editor first when after.edit asks (`src/editor*.odin`).

## Shortcuts

`src/shortcuts.odin` binds one global shortcut per kind of capture through `gt:shortcuts`: on Linux the desktop portal's
GlobalShortcuts (the system may give other keys than the ones asked: the settings show which), on Windows
RegisterHotKey. The commands (`cliche --region`) stay for a compositor's own bindings.

## Settings

`src/settings.odin` is the registry (one `config.Def` per preference, a category per page); the appearance and session
preferences are the toolkit's standard ones (`prefs_page.standard_register`). The settings are a mode of the main
window (`src/history_view.odin`): `src/settings_view.odin` builds them with `gt:prefs_page` in place of the history, with
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

After a save, the same PNG goes to the uploader chosen (`src/uploader.odin`: ShareX's `.sxcu` files and their syntax),
on the worker; its address takes the picture's place on the clipboard. `cliche --ocr` reads the text of a region with
`gt:ocr` on the worker, as `cliche --qr` reads a QR code with `gt:qr`.
