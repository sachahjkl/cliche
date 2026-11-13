// cliche: screenshots for Linux (Wayland first) and Windows, on gui_toolkit.
//
// One process for the session lives in the notification area (app.odin). A start of `cliche --region` when it runs hands
// it the command and ends at once: on Wayland the compositor binds a key to that command.
package cliche

import "core:fmt"
import "core:os"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"

APP_VERSION :: "0.2.0"

USAGE :: `cliche: screenshots

  cliche                      start cliche in the notification area (nothing when it runs)
  cliche --region             choose a rectangle, a window or a screen on the frozen desktop
  cliche --screen             capture the screen under the pointer
  cliche --window             capture the window in front
  cliche --qr                 read the QR code in a region
  cliche --ocr                read the text in a region
  cliche --record             record a region as an MP4 video; the same command again stops it
  cliche --record-gif         record a region as an animated GIF; the same command again stops it
  cliche --edit               capture a region and open it in the editor
  cliche --history            show the captures kept
  cliche --workflows          edit what happens after each capture
  cliche --settings           open the settings

Each capture runs its workflow: by default a screenshot is copied and saved, a QR code's
or a region's text is copied.
  cliche --quit               end the running cliche
  cliche version
  --pref name=value           a preference for this run only

A command starts cliche when it does not run. Bind keys to these commands in your compositor (Wayland).
`

main :: proc() {
	os.exit(run(os.args[1:]))
}

run :: proc(all_args: []string) -> int {
	timing_init()
	when CLICHE_SHOTS != "" { return shots_run(CLICHE_SHOTS, len(all_args) > 0 ? all_args[0] : "") }
	prefs: config.Prefs
	args, problems := prefs_open(&prefs, all_args)
	defer config.prefs_destroy(&prefs)
	for p in problems { fmt.eprintfln("cliche: %s", p) }
	if len(args) > 1 { fmt.eprint(USAGE); return 2 }
	arg := len(args) > 0 ? args[0] : ""
	switch arg {
	case "":
		return start(&prefs, {verb = .Ping})
	case "version", "--version":
		fmt.printfln("cliche %s", APP_VERSION)
		return 0
	case "help", "-h", "--help":
		fmt.print(USAGE)
		return 0
	}
	verb, ok := verb_of_flag(arg)
	if !ok { fmt.eprint(USAGE); return 2 }
	if verb == .Quit {
		// (no cliche to end: nothing is started for it)
		command_send({verb = .Quit})
		return 0
	}
	c := Command{verb = verb}
	if verb in VERBS_WITH_TOKEN { c.token = platform.activation_token_from_env(context.temp_allocator) }
	return start(&prefs, c)
}

// The running cliche is handed `c`; when none runs, this process becomes it and runs `c` itself.
@(private = "file")
start :: proc(prefs: ^config.Prefs, c: Command) -> int {
	outcome, owner := instance.acquire({name = INSTANCE_NAME, wait_ms = ACQUIRE_WAIT_MS}, transmute([]u8)command_format(c))
	switch outcome {
	case .First:     return app_run(prefs, owner, c)
	case .Forwarded: return 0
	case .Other_Instance:
		fmt.eprintln("cliche: another copy of cliche runs")
		return 1
	case .Unresponsive:
		fmt.eprintln("cliche: a cliche runs and does not answer")
		return 1
	}
	return 1
}
