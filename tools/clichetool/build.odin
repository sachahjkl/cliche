package clichetool

// build, test, check: the toolkit's (toolbox.build_commands), over cliche's options; shots: the windows offscreen.

import "core:fmt"
import "core:os"
import tk_changelog "gt:changelog"
import cli "gt:cli"
import toolbox "gt:toolbox"

// The French catalogue has every text of the code, translated: `clichetool i18n fr` writes it, check compares it.
I18N := toolbox.I18n_Catalogues{dirs = {"src"}, folder = "i18n"}

// (notices: the notices name every crate the executable links: a new crate in the toolkit's native libraries changes them)
build_options :: proc() -> toolbox.Build_Options {
	p := project()
	return {project = p, changelog_command = tk_changelog.command(p), catalogues = I18N, notices = true}
}

// The settings' pages, the editor, the history and the workflows, drawn offscreen by a build of the program with
// CLICHE_SHOTS (src/shots.odin): no window opens.
run_shots :: proc(args: []string) -> cli.Exit {
	p := project()
	folder := len(args) > 0 ? args[0] : "build/shots"
	// (the windows named after the folder, else the defaults: "motion", frame by frame, only when named)
	windows := len(args) > 1 ? args[1:] : []string{"settings", "editor", "history", "workflows", "record"}
	if !toolbox.build_native(p) { return .Failed }
	_ = os.make_directory_all(folder)
	out := fmt.tprintf("build/cliche-shots%s", ODIN_OS == .Windows ? ".exe" : "")
	if !toolbox.run(toolbox.odin_command(p, "build", "", {fmt.tprintf("-out:%s", out), "-debug", "-o:none", fmt.tprintf("-define:CLICHE_SHOTS=%s", folder)}), {echo = true}) { return .Failed }
	// (one window a run: a headless renderer has only its first one)
	for window in windows {
		if !toolbox.run({out, window}, {echo = true}) { return .Failed }
	}
	return .Done
}
