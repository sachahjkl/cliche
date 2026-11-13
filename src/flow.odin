package cliche

// The capture flow: one state machine for a screenshot, from the trigger to its picture. The app (app.odin) runs the side
// effects of each state it enters (a job for the worker, the overlay shown or hidden, a notification); the states and
// what may follow each are here, pure, and tested without a window (flow_test.odin).
//
//   Idle -> Capturing -> Selecting -> Encoding -> (Handed) Idle | Failed -> Idle
//                     \______________/
//                      (screen, window: no selection)
//
// The picture is handed to a run of the capture's workflow (workflow_app.odin), which goes on outside this flow: the next
// capture may start at once. A trigger while a capture goes on is refused: one capture at a time.

import capture "gt:capture"
import i18n "gt:i18n"

// Where the picture comes from.
Source :: enum u8 {
	Region,   // a rectangle (or a window, or an output) chosen on the frozen desktop
	Screen,   // the output under the pointer, no interface
	Window,   // the window in front, no interface
}

SOURCE_NAMES := [Source]string{.Region = "region", .Screen = "screen", .Window = "window"}

// Why a capture failed.
Flow_Error :: enum u8 {
	None,
	Unsupported,   // the system offers no capture here (gt:capture .Unsupported), or not of this source
	Denied,        // the user or the system refused (a portal's dialog)
	Gone,          // the output or the window went away
	Failed,        // the system said no
	Empty,         // nothing to take: no output, no window, an empty rectangle
	Not_Saved,     // the file could not be written
	No_Qr,         // the picture holds no QR code that reads
	No_Text,       // no text could be read in the picture
	Not_Uploaded,  // the upload failed, and nothing was saved
	No_Ocr,        // no engine reads text here (gt:ocr: Tesseract on Linux, Windows' own)
	No_Workflow,   // no workflow runs for this capture
}

FLOW_ERROR_TEXT := [Flow_Error]string{
	.None        = "",
	.Unsupported = i18n.later("this desktop offers no way to capture this"),
	.Denied      = i18n.later("the capture was refused"),
	.Gone        = i18n.later("the screen or the window is gone"),
	.Failed      = i18n.later("the system could not capture the screen"),
	.Empty       = i18n.later("there is nothing to capture"),
	.Not_Saved   = i18n.later("the picture could not be saved"),
	.No_Qr       = i18n.later("no QR code could be read in the picture"),
	.Not_Uploaded = i18n.later("the picture could not be uploaded"),
	.No_Text     = i18n.later("no text could be read in the picture"),
	.No_Ocr      = i18n.later("this system reads no text: install Tesseract and its languages (Linux), or a Windows language with text recognition"),
	.No_Workflow = i18n.later("no workflow runs for this capture: choose one in the Workflows of the main window"),
}

Flow_Idle      :: struct {}
Flow_Capturing :: struct { source: Source }   // the worker reads the screen
Flow_Selecting :: struct {}                   // the overlay shows the frozen desktop (Region only)
Flow_Encoding  :: struct { source: Source }   // the picture is cut (a region) and handed to its workflow
Flow_Done      :: struct { source: Source }
Flow_Failed    :: struct { source: Source, error: Flow_Error }

Flow :: union #no_nil { Flow_Idle, Flow_Capturing, Flow_Selecting, Flow_Encoding, Flow_Done, Flow_Failed }

Flow_Trigger        :: struct { source: Source }   // a command, a hotkey, the tray
Flow_Captured       :: struct {}                   // the worker has the picture
Flow_Capture_Failed :: struct { error: Flow_Error }
Flow_Confirmed      :: struct {}                   // the user took a rectangle
Flow_Cancelled      :: struct {}                   // Escape, a close
Flow_Handed         :: struct {}                   // the picture went to a run of its workflow: the capture is over
Flow_Saved          :: struct {}                   // the picture's work is done (a test's flow: the app hands it on)
Flow_Save_Failed    :: struct { error: Flow_Error }
Flow_Reset          :: struct {}                   // the outcome was told: ready for the next

Flow_Event :: union {
	Flow_Trigger, Flow_Captured, Flow_Capture_Failed, Flow_Confirmed, Flow_Cancelled, Flow_Handed, Flow_Saved, Flow_Save_Failed,
	Flow_Reset,
}

// The state after `e` in `f`. ok false: `e` means nothing in `f` (a trigger while busy, a late result), and `f` stays.
flow_step :: proc(f: Flow, e: Flow_Event) -> (next: Flow, ok: bool) {
	switch s in f {
	case Flow_Idle, Flow_Done, Flow_Failed:
		#partial switch v in e {
		case Flow_Trigger: return Flow_Capturing{v.source}, true
		case Flow_Reset:
			if _, idle := f.(Flow_Idle); idle { break }
			return Flow_Idle{}, true
		}
	case Flow_Capturing:
		#partial switch v in e {
		case Flow_Captured:
			if s.source == .Region { return Flow_Selecting{}, true }
			return Flow_Encoding{s.source}, true
		case Flow_Capture_Failed: return Flow_Failed{s.source, v.error}, true
		case Flow_Cancelled:      return Flow_Idle{}, true
		}
	case Flow_Selecting:
		#partial switch v in e {
		case Flow_Confirmed: return Flow_Encoding{.Region}, true
		case Flow_Cancelled: return Flow_Idle{}, true
		case Flow_Capture_Failed: return Flow_Failed{.Region, v.error}, true
		}
	case Flow_Encoding:
		#partial switch v in e {
		case Flow_Saved:       return Flow_Done{s.source}, true
		// (the run of the workflow holds the picture now, outside this flow: the next capture may start while it runs, or
		// while its editor is open)
		case Flow_Handed:      return Flow_Idle{}, true
		case Flow_Save_Failed: return Flow_Failed{s.source, v.error}, true
		}
	}
	return f, false
}

flow_busy :: proc(f: Flow) -> bool {
	#partial switch _ in f {
	case Flow_Capturing, Flow_Selecting, Flow_Encoding: return true
	}
	return false
}

// The flow's error for a gt:capture error.
flow_error_of :: proc(e: capture.Error) -> Flow_Error {
	switch e {
	case .None:        return .None
	case .Unsupported: return .Unsupported
	case .Denied:      return .Denied
	case .Gone:        return .Gone
	case .Failed:      return .Failed
	}
	return .Failed
}
