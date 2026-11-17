// cliche: screenshots for Linux (Wayland first) and Windows, on gui_toolkit.
//
// One process for the session lives in the notification area (app.odin). A start of `cliche --region` when it runs hands
// it the command and ends at once: on Wayland the compositor binds a key to that command.
package cliche

import "core:fmt"
import "core:os"
import cli "gt:cli"
import config "gt:config"
import instance "gt:instance"
import "gt:platform"
import process "gt:process"
import setup "gt:setup"

APP_VERSION :: "0.22.0"
// What changed, version by version: the settings' What's new page (in the program, beside its site's changelog).
CHANGELOG :: #load("../CHANGELOG.md", string)

USAGE :: `cliche: screenshots

  cliche                      start cliche in the notification area (nothing when it runs)
  cliche --region             choose a rectangle, a window or a screen on the frozen desktop
  cliche --screen             capture the screen under the pointer
  cliche --window             capture the window in front
  cliche --all-screens        capture every screen in one picture
  cliche --last-region        capture the last region chosen again, with no overlay
  cliche --color              pick a colour on the screen: a click copies #rrggbb (Shift: rgb())
  cliche --ruler              measure on the screen: a drag gives a line's length and angle; Escape ends
  cliche --auto-capture       start a capture every few seconds (capture.auto_interval); again: stop it
  cliche --scrolling-capture  choose a page that scrolls: one tall picture of it (Windows, X11); again: cancel
  cliche --qr                 read the QR code in a region
  cliche --ocr                read the text in a region
  cliche --record             record a region as an MP4 video; the same command again stops it
  cliche --record-gif         record a region as an animated GIF; the same command again stops it
  cliche --edit               capture a region and open it in the editor
  cliche --upload-clipboard   upload what the clipboard holds (a picture, files or a text): its workflow runs
  cliche --upload-file        choose files to upload: its workflow runs on each
  cliche --history            show the captures kept
  cliche --workflows          edit what happens after each capture
  cliche --settings           open the settings
  cliche --setup              the install's dialog: install cliche for you, repair, upgrade or uninstall it (also
                              in the settings: Installation)
  cliche --install            install this copy for you, without a window
  cliche --uninstall          take the install away (the history and the settings stay)
  cliche --status             what is installed, and whether cliche runs (exit 0 installed, 2 to repair,
                              1 not installed)

Each capture runs its workflow: by default a region opens in the editor, then is copied and
saved on Done; the screen and a window are copied and saved; a QR code's or a region's text
is copied.
  cliche --quit               end the running cliche
  cliche version
  --pref name=value           a preference for this run only

A command starts cliche when it does not run. Bind keys to these commands in your compositor (Wayland).
`

main :: proc() {
	cli.exit(run(os.args[1:]))
}

run :: proc(all_args: []string) -> cli.Exit {
	when CLICHE_SHOTS != "" { return shots_run(CLICHE_SHOTS, len(all_args) > 0 ? all_args[0] : "") }
	// (once, before the preferences are read: the folders of the old lowercase name become the vendor's; the log is not
	// open yet, so a folder that cannot move is said on stderr)
	if _, why := platform.user_dirs_move(APP_NAME, APP_FOLDER); why != "" { fmt.eprintfln("cliche: %s", why) }
	prefs: config.Prefs
	args, problems := prefs_open(&prefs, all_args)
	defer config.prefs_destroy(&prefs)
	for p in problems { fmt.eprintfln("cliche: %s", p) }
	// (--install, --uninstall, --status and --quit: no window, whether cliche runs or not; --setup is a verb: the running
	// cliche shows it)
	if cmd, _ := setup.command_of(args[:]); setup.command_alone(cmd) {
		return setup.command_run(cmd, setup_options(), process.console_write)
	}
	if len(args) > 1 { fmt.eprint(USAGE); return .Usage }
	arg := len(args) > 0 ? args[0] : ""
	switch arg {
	case "":
		return start(&prefs, {verb = .Ping})
	case "version", "--version":
		fmt.printfln("cliche %s", APP_VERSION)
		return .Done
	case "help", "-h", "--help":
		fmt.print(USAGE)
		return .Done
	}
	verb, ok := verb_of_flag(arg)
	if !ok { fmt.eprint(USAGE); return .Usage }
	c := Command{verb = verb}
	if verb in VERBS_WITH_TOKEN { c.token = platform.activation_token_from_env(context.temp_allocator) }
	return start(&prefs, c)
}

// The running cliche is handed `c`; when none runs, this process becomes it and runs `c` itself.
@(private = "file")
start :: proc(prefs: ^config.Prefs, c: Command) -> cli.Exit {
	outcome, owner := instance.acquire({name = INSTANCE_NAME, wait_ms = ACQUIRE_WAIT_MS}, transmute([]u8)command_format(c))
	switch outcome {
	case .First:
		if !app_run(prefs, owner, c) { return .Failed }
		return .Done
	case .Forwarded: return .Done
	case .Other_Instance:
		fmt.eprintln("cliche: another copy of cliche runs")
		return .Failed
	case .Unresponsive:
		fmt.eprintln("cliche: a cliche runs and does not answer")
		return .Failed
	}
	return .Failed
}
