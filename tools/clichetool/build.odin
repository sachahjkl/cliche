package clichetool

// build, test, check, shots: the program and its tests, the same steps on a laptop and in the CI.

import "core:fmt"
import "core:os"
import tk_changelog "gt:changelog"
import toolbox "gt:toolbox"

run_build :: proc(args: []string) -> int {
	p := project()
	release := len(args) > 0 && args[0] == "release"
	if !toolbox.build_native(p) { return toolbox.EXIT_FAILED }
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
	if !toolbox.run(toolbox.odin_command(p, "build", "", extra[:]), {echo = true}) { return toolbox.EXIT_FAILED }
	fmt.printfln("built %s", PROGRAM)
	return toolbox.EXIT_DONE
}

run_test :: proc(args: []string) -> int {
	p := project()
	if !toolbox.build_native(p) { return toolbox.EXIT_FAILED }
	_ = os.make_directory("build")
	out := fmt.tprintf("-out:build/test_src%s", ODIN_OS == .Windows ? ".exe" : "")
	return toolbox.run(toolbox.odin_command(p, "test", "", {out}), {echo = true}) ? toolbox.EXIT_DONE : toolbox.EXIT_FAILED
}

run_check :: proc(args: []string) -> int {
	p := project()
	if !toolbox.run(toolbox.odin_command(p, "check"), {echo = true}) { return toolbox.EXIT_FAILED }
	when ODIN_OS != .Windows {
		if !toolbox.check_windows(p) { return toolbox.EXIT_FAILED }   // (the Linux code is checked on Linux)
	}
	if !toolbox.run(toolbox.odin_command(p, "check", "tools/clichetool"), {echo = true}) { return toolbox.EXIT_FAILED }
	if !toolbox.check_scopes("src") { return toolbox.EXIT_FAILED }
	errors, n := tk_changelog.check(tk_changelog.project_options(&p))
	for e in errors { fmt.eprintfln("changelog: %s", e) }
	if len(errors) > 0 { return toolbox.EXIT_FAILED }
	fmt.printfln("changelog: %d fragments, well formed", n)
	if run_test(nil) != toolbox.EXIT_DONE { return toolbox.EXIT_FAILED }
	return run_build({"release"})
}

// The settings' pages, the editor, the history and the workflows, drawn offscreen by a build of the program with
// CLICHE_SHOTS (src/shots.odin): no window opens.
run_shots :: proc(args: []string) -> int {
	p := project()
	folder := len(args) > 0 ? args[0] : "build/shots"
	// (the windows named after the folder, else the defaults: "motion", frame by frame, only when named)
	windows := len(args) > 1 ? args[1:] : []string{"settings", "editor", "history", "workflows", "record"}
	if !toolbox.build_native(p) { return toolbox.EXIT_FAILED }
	_ = os.make_directory_all(folder)
	out := fmt.tprintf("build/cliche-shots%s", ODIN_OS == .Windows ? ".exe" : "")
	if !toolbox.run(toolbox.odin_command(p, "build", "", {fmt.tprintf("-out:%s", out), "-debug", "-o:none", fmt.tprintf("-define:CLICHE_SHOTS=%s", folder)}), {echo = true}) { return toolbox.EXIT_FAILED }
	// (one window a run: a headless renderer has only its first one)
	for window in windows {
		if !toolbox.run({out, window}, {echo = true}) { return toolbox.EXIT_FAILED }
	}
	return toolbox.EXIT_DONE
}
