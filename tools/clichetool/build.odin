package clichetool

// build, test, check, shots: the program and its tests, the same steps on a laptop and in the CI.

import "core:fmt"
import "core:os"
import tk_changelog "gt:changelog"
import cli "gt:cli"
import toolbox "gt:toolbox"

run_build :: proc(args: []string) -> cli.Exit {
	p := project()
	release := len(args) > 0 && args[0] == "release"
	if !toolbox.build_native(p) { return .Failed }
	_ = os.make_directory("build")
	// (while iterating: no optimisation, the fastest build; release: what ships)
	mode := release ? []string{"-o:speed"} : []string{"-debug", "-o:none"}
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("-out:%s", PROGRAM))
	append(&extra, ..mode)
	// (Windows: no console of its own: it lives in the notification area)
	when ODIN_OS == .Windows {
		if release { append(&extra, "-subsystem:windows") }
	}
	if !toolbox.run(toolbox.odin_command(p, "build", "", extra[:]), {echo = true}) { return .Failed }
	fmt.printfln("built %s", PROGRAM)
	return .Done
}

run_test :: proc(args: []string) -> cli.Exit {
	p := project()
	if !toolbox.build_native(p) { return .Failed }
	_ = os.make_directory("build")
	out := fmt.tprintf("-out:build/test_src%s", ODIN_OS == .Windows ? ".exe" : "")
	return toolbox.ended(toolbox.run(toolbox.odin_command(p, "test", "", {out}), {echo = true}))
}

run_check :: proc(args: []string) -> cli.Exit {
	p := project()
	if !toolbox.run(toolbox.odin_command(p, "check"), {echo = true}) { return .Failed }
	when ODIN_OS != .Windows {
		if !toolbox.check_windows(p) { return .Failed }   // (the Linux code is checked on Linux)
		if !toolbox.check_darwin(p) { return .Failed }
	}
	if !toolbox.run(toolbox.odin_command(p, "check", "tools/clichetool"), {echo = true}) { return .Failed }
	if !toolbox.check_scopes("src") { return .Failed }
	errors, n := tk_changelog.check(tk_changelog.project_options(&p))
	for e in errors { fmt.eprintfln("changelog: %s", e) }
	if len(errors) > 0 { return .Failed }
	fmt.printfln("changelog: %d fragments, well formed", n)
	// (the notices name every crate the executable links: a new crate in the toolkit's native libraries changes them)
	if why := toolbox.third_party_notices(p, toolbox.NOTICES_FILE, true); why != "" { fmt.eprintfln("check: %s", why); return .Failed }
	// (the French catalogue has every text of the code, translated: `clichetool i18n fr` writes it)
	if e := toolbox.i18n_catalogue({"src"}, "i18n/fr.txt", "fr", check = true); e != "" { fmt.eprintln(e); return .Failed }
	if run_test(nil) != .Done { return .Failed }
	if e := run_build({"release"}); e != .Done { return e }
	// (Windows: the release build starts, with its icon, through its launcher: a broken manifest once made Windows refuse
	// every program, and nothing but starting it shows that)
	return toolbox.ended(toolbox.check_launcher(project()))
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
