type: Fixed

**Closing the editor right after Copy keeps the copy**: closing while filters or GPU readback are still running defers the close until the copy goes to the worker.
