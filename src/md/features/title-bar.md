# cliche's title bar

cliche's normal windows draw their own title bar, as every program of the toolkit does. Code: `src/title_bar.odin`.

## Purpose

- **One look for the toolkit's programs.** papier, classeur and inspecteur draw their title bar; cliche did not
  (`window.system_title` was forced on and hidden). Its windows looked like another family's.
- **GNOME draws no title bar.** There, a window with the system's decorations has none at all: it cannot be moved,
  maximised or closed with the pointer. cliche's own bar works on every desktop.

## Decisions

- **The default is the toolkit's: cliche's own title bar.** `window.system_title` shows on the Window page of the
  settings, as in the other programs. On, the system draws the title bar where it can; on GNOME cliche keeps its own,
  and the setting says so under its line.
- **It follows the setting at once.** A change calls `platform.set_integrated_title` on each normal window
  (`app_title_follow`). The bar is built only while the window's title bar is integrated, so the switch shows in the
  next frame. The views' windows follow their owner window by themselves (the toolkit).
- **Which windows.**
  - The history window (its history, its settings and its workflows are modes of one window): the bar spans the whole
    window, above the views docked at its edges; under it, each mode's own bar.
  - Each editor: the bar above its two bars (`editor-bars.md`), and above the "Reading the picture…" page too.
  - Not the pins, the region's overlay and the recording's overlay. They are layers over the other programs, without
    decorations by nature: a pin is its picture and moves by its own drag. Their fallback windows (no layer shell) keep
    what the system gives, as before.
- **What the bar holds.** cliche's mark, the window's name ("cliche", "cliche editor"), then the toolkit's window
  buttons. Its empty parts and its text move the window; a double click maximises it. Refused: putting the history's
  search or the editor's tools in it: each mode keeps its own bar, and a title bar the same in every window.

## Subtle points

- The window buttons' close is the system's close: the history window hides, an editor asks before it drops changes.
- The bar is built while `platform.is_integrated_title` says so, whatever the window: an offscreen window (the
  screenshots of `clichetool shots`, the tests) shows it as the platform reports it. The run-time switch leaves
  offscreen windows alone.
