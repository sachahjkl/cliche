# Auto capture

A capture every N seconds (`capture.auto_interval`) of what `capture.auto_source` says: the screen under the pointer,
the window in front, all the screens, or the last region. The tray's check item starts and stops it, as do the palette's
command and `cliche --auto-capture`. Each capture runs the workflow of its trigger, as a press of its shortcut does.

## A tick is a command in the inbox

The thread does not capture. At each tick it puts the capture's command (`screen`, `window`, `all-screens`,
`last-region`) in the app's inbox, where a second start's commands go, with its run's generation. So:

- The capture flow stays one state machine on the interface's thread. A tick while a capture, the ruler or the colour
  picker is under way is refused as a second press is: one capture at a time, nothing queued.
- Nothing is shared between the threads but the inbox, which has its lock already.
- The loop needs no timeout: the post wakes it.

Refused: a timer in the loop (`app_wait` with a deadline). It puts a time in the loop's wait for one feature, and every
other wait would have to know it.

## Stopping: no join

The interface thread never waits for the thread. Refused: a stop that signals and joins. The join is short, since the
thread is woken, but it is a wait on the interface thread, at each change of a preference and at quit, and the
program's rule allows none.

So each run is its own heap struct (`Auto_Run`), held by its thread and by the owner with a count of two: whichever lets
go last frees it, on the heap allocator, whatever thread it is. The thread is started with self cleanup, so nobody
joins it. A stop:

1. sets the owner's generation to 0, so the run's ticks stop counting at once;
2. sets the run's `stopping` under the run's lock and signals its condition variable;
3. lets the run go. The thread wakes, sees `stopping`, lets the run go and ends.

A restart (a preference changed) stops the old run that way and starts a new one at once, with a new generation. The
old one ends by itself when it wakes.

The thread waits on the condition variable with the time left, not a sleep: a stop wakes it at once.

## Generations

Each run has a generation; the owner's atomic holds the current one, 0 for none. A tick carries its run's generation,
and it is dropped twice if that is not the current one: when the thread posts it (`app_auto_tick`), and when the inbox
reads it (`app_inbox`), because a tick may have been queued just before the stop.

## Quit

The quit stops the run, without waiting, before the inbox and the app are freed. That is safe because the thread posts
under the run's lock and tests `stopping` under it first: once the stop has taken that lock and set `stopping`, the
thread never calls the post again, and the post is the only path that touches the app. After that the thread only
releases its own run and ends; the app and its inbox may go first. The one wait left is the stop's lock: if the thread
is posting at that moment, the stop waits for one append to the inbox, which already takes the inbox's own lock against
the second starts. It never waits for the interval or for the thread to end.

Refused: keeping the inbox alive past the app (a shared, counted inbox). It adds an owner for one thread's sake, where
the run's lock already orders the last post before the stop.

The ticks keep to their schedule (`due += interval`): a slow post does not drift them. A tick late by more than an
interval is dropped, not caught up in a burst.

## Subtle points

- The first capture comes after one interval, not at once: at once, it would take the menu or the palette that started
  it.
- The last region with none chosen yet opens the region's overlay at the first tick (`source_resolve`); the next ticks
  take that rectangle.
- A change of the interval or the source while it runs starts a new run (`app_auto_capture_follow_prefs`): a run reads
  them only at its start, so no lock guards them.
- The tray's item is a check item; its words say the interval. The menu is built again when either changes.
