# Architecture

## One resident process

`cliche` starts once per session and stays in the notification area (`src/app.odin`). A second start, such as
`cliche --region` bound to a key by the compositor, hands its command to the running one over gui_toolkit's instance
socket (`src/commands.odin`) and ends at once. A shortcut therefore costs no start-up.

At rest the process holds: a hidden anchor window (the tray icon, the notifications, the hotkeys and the clipboard are a
window's), the worker's thread with the capture session already open, and the thread that hears other starts. The
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

A chain of actions (`src/actions.odin`): copy, save; upload, QR, editor to come.
