type: Fixed

**The region follows the pointer to every monitor.** On Windows, Cliche started from the tray always opened the region's selection on the first monitor it used, the primary in practice. It now opens on the monitor the pointer is on (also on X11).
