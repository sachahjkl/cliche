package cliche

// What a start of `cliche` asks the running one: one line of text, "<verb> [token]", over the instance socket. On
// Wayland this is how a shortcut works: the compositor binds a key to `cliche --region`, whose process hands the verb to
// the running cliche and ends at once.

import "core:strings"
import instance "gt:instance"

INSTANCE_NAME :: "cliche.main"
SEND_WAIT_MS  :: 1000
ACQUIRE_WAIT_MS :: 1500

Verb :: enum u8 { Ping, Region, Screen, Window, All_Screens, Last_Region, Color, Qr, Ocr, Record, Record_Gif, Edit, Upload_Clipboard, Upload_File, History, Workflows, Settings, Setup, Quit }

// (the two uploads' words are their triggers' too: TRIGGER_NAMES)
VERB_NAMES := [Verb]string{
	.Ping = "ping", .Region = "region", .Screen = "screen", .Window = "window", .All_Screens = "all-screens", .Last_Region = "last-region", .Color = "color",
	.Qr = "qr", .Ocr = "ocr", .Record = "record", .Record_Gif = "record-gif", .Edit = "edit", .Upload_Clipboard = "upload-clipboard", .Upload_File = "upload-file",
	.History = "history", .Workflows = "workflows", .Settings = "settings", .Setup = "setup", .Quit = "quit",
}

// The verbs whose window takes the keyboard: the launcher's activation token goes with them (Wayland). (The last region
// opens the region's overlay when none was chosen yet.)
VERBS_WITH_TOKEN :: bit_set[Verb]{.Region, .Last_Region, .Color, .Qr, .Ocr, .Record, .Record_Gif, .Edit, .Upload_File, .History, .Workflows, .Settings, .Setup}

Command :: struct {
	verb:  Verb,
	token: string,   // the activation token the second start was given ("" none); the message's bytes, not owned
}

// The verb of a command-line flag ("--region"), ok false for another argument.
verb_of_flag :: proc(arg: string) -> (v: Verb, ok: bool) {
	if !strings.has_prefix(arg, "--") { return }
	for name, verb in VERB_NAMES {
		if verb != .Ping && name == arg[2:] { return verb, true }
	}
	return
}

command_format :: proc(c: Command, allocator := context.temp_allocator) -> string {
	if c.verb in VERBS_WITH_TOKEN && c.token != "" && !strings.contains_any(c.token, " \n") {
		return strings.concatenate({VERB_NAMES[c.verb], " ", c.token}, allocator)
	}
	return strings.clone(VERB_NAMES[c.verb], allocator)
}

command_parse :: proc(text: string) -> (c: Command, ok: bool) {
	f := strings.fields(text, context.temp_allocator)
	if len(f) == 0 || len(f) > 2 { return }
	for name, v in VERB_NAMES {
		if name != f[0] { continue }
		if len(f) == 2 {
			if v not_in VERBS_WITH_TOKEN { return }
			c.token = f[1]
		}
		c.verb = v
		return c, true
	}
	return
}

// Whether a cliche runs and answers (--status: setup.Setup_Options.running): a ping does nothing there.
cliche_running :: proc() -> bool { return command_send({verb = .Ping}) }

// Hands `c` to the running cliche. False when none runs.
command_send :: proc(c: Command) -> bool {
	return instance.send({name = INSTANCE_NAME, wait_ms = SEND_WAIT_MS}, transmute([]u8)command_format(c)) == .Forwarded
}
