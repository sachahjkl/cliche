package clichetool

// build, test, check: the program and its tests, the same steps on a laptop and in the CI.

import "core:fmt"
import "core:os"
import "core:strings"
import tk_changelog "gt:changelog"
import toolbox "gt:toolbox"

// What a build on Linux needs: the toolkit's native text backend, and the Rust standard library that both it and
// wgpu-native carry linked once (the toolkit's own CI does the same).
LINUX_DEFINES :: "-define:FONT_BACKEND=native"
LINUX_LINK    :: "-extra-linker-flags:-Wl,--allow-multiple-definition"
TEST_PACKAGES :: [?]string{"src"}
when ODIN_OS == .Windows {
	PROGRAM :: "build/cliche.exe"
} else {
	PROGRAM :: "build/cliche"
}

toolkit :: proc() -> string {
	if v := os.get_env("GT", context.temp_allocator); v != "" { return v }
	return "ext/gui_toolkit"
}

collection :: proc() -> string { return fmt.tprintf("-collection:gt=%s/src", toolkit()) }

// An odin command on a package of the program: the toolkit's collection, -vet, and on Linux the text backend.
odin_cmd :: proc(verb, pkg: string, extra: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, pkg, collection(), "-vet")
	when ODIN_OS == .Linux {
		append(&cmd, LINUX_DEFINES)
		if verb != "check" { append(&cmd, LINUX_LINK) }   // (check links nothing)
	}
	append(&cmd, ..extra)
	return cmd[:]
}

// The toolkit's text library, built by its own tool (it skips what is up to date).
build_text :: proc() -> bool {
	when ODIN_OS == .Linux {
		_ = os.make_directory_all(fmt.tprintf("%s/build", toolkit()))   // (a fresh checkout has none: the linker writes tk there)
		return toolbox.run({"odin", "run", "tools/tk", "-out:build/tk", "--", "build_text"}, {dir = toolkit(), echo = true})
	} else {
		return true
	}
}

run_build :: proc(args: []string) -> int {
	release := len(args) > 0 && args[0] == "release"
	if !build_text() { return 1 }
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
	if !toolbox.run(odin_cmd("build", "src", extra[:]), {echo = true}) { return 1 }
	fmt.printfln("built %s", PROGRAM)
	return 0
}

run_test :: proc(args: []string) -> int {
	if !build_text() { return 1 }
	_ = os.make_directory("build")
	for pkg in TEST_PACKAGES {
		name, _ := strings.replace_all(pkg, "/", "_", context.temp_allocator)
		out := fmt.tprintf("-out:build/test_%s%s", name, ODIN_OS == .Windows ? ".exe" : "")
		if !toolbox.run(odin_cmd("test", pkg, {out}), {echo = true}) { return 1 }
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	if !toolbox.run(odin_cmd("check", "src", nil), {echo = true}) { return 1 }
	if !check_windows() { return 1 }
	if !toolbox.run({"odin", "check", "tools/clichetool", collection(), "-vet"}, {echo = true}) { return 1 }
	if changelog_check() != 0 { return 1 }
	if run_test(nil) != 0 { return 1 }
	return run_build({"release"})
}

// The version of the program: APP_VERSION in src/main.odin.
app_version :: proc() -> string {
	text, err := os.read_entire_file("src/main.odin", context.temp_allocator)
	if err != nil { return "" }
	for line in strings.split_lines(string(text), context.temp_allocator) {
		rest := strings.trim_prefix(line, "APP_VERSION :: \"")
		if rest == line { continue }
		if end := strings.index_byte(rest, '"'); end >= 0 { return rest[:end] }
	}
	return ""
}

changelog_options :: proc() -> tk_changelog.Options {
	return {link = "https://github.com/sachahjkl/cliche/releases/tag/v%s", version = proc(root: string) -> string { return app_version() }}
}

changelog_check :: proc() -> int {
	errors, n := tk_changelog.check(changelog_options())
	for e in errors { fmt.eprintfln("changelog: %s", e) }
	if len(errors) > 0 { return 1 }
	fmt.printfln("changelog: %d fragments, well formed", n)
	return 0
}

run_changelog :: proc(args: []string) -> int {
	USAGE :: "changelog new <Added|Changed|Deprecated|Removed|Fixed|Security> <text> | check | preview"
	if len(args) == 0 { fmt.eprintln(USAGE); return EXIT_USAGE }
	switch args[0] {
	case "new":
		if len(args) < 3 { fmt.eprintln(USAGE); return EXIT_USAGE }
		path, why := tk_changelog.new_fragment(".", args[1], "", strings.join(args[2:], " ", context.temp_allocator))
		if why != "" { fmt.eprintfln("changelog: %s", why); return 1 }
		fmt.println(path)
		return 0
	case "check":
		return changelog_check()
	case "preview":
		text, errors := tk_changelog.preview(".")
		for e in errors { fmt.eprintfln("changelog: %s", e) }
		if len(errors) > 0 { return 1 }
		fmt.print(text != "" ? text : "changelog: no fragment, nothing to publish\n")
		return 0
	}
	fmt.eprintln(USAGE)
	return EXIT_USAGE
}

// The Windows code, checked from Linux: it is not run here, a check at least sees it compile. wgpu's package refuses to be
// checked without its Windows library, which checking does not link: the check runs on an Odin root of links to the real
// one, whose wgpu package is a copy with an empty library beside it (Odin follows links: a linked file is in the real
// folder). The flake's wrapper keeps an ODIN_ROOT it is given.
CHECK_ROOT :: "build/odin_root"
WGPU_WINDOWS_LIB :: "lib/wgpu-windows-x86_64-msvc-release/lib/wgpu_native.lib"

check_windows :: proc() -> bool {
	when ODIN_OS == .Windows {
		return true   // (the Linux code is checked on Linux)
	} else {
		out, code := toolbox.capture({"odin", "root"})
		real := strings.trim_right(strings.trim_space(out), "/")
		if code != 0 || real == "" { fmt.eprintln("clichetool: odin root gave nothing"); return false }
		if !check_root_make(real) { return false }
		env := toolbox.env_with({"ODIN_ROOT"}, fmt.tprintf("ODIN_ROOT=%s/", CHECK_ROOT))
		return toolbox.run({"odin", "check", "src", collection(), "-vet", "-target:windows_amd64"}, {echo = true, env = env})
	}
}

@(private = "file")
check_root_make :: proc(real: string) -> bool {
	_ = os.remove_all(CHECK_ROOT)
	wgpu := CHECK_ROOT + "/vendor/wgpu"
	if os.make_directory_all(wgpu) != nil { fmt.eprintfln("clichetool: %s cannot be made", wgpu); return false }
	link_all :: proc(from, into: string, except: string) -> bool {
		entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
		if err != nil { fmt.eprintfln("clichetool: %s cannot be read", from); return false }
		for e in entries {
			if e.name == except { continue }
			if os.symlink(e.fullpath, fmt.tprintf("%s/%s", into, e.name)) != nil { fmt.eprintfln("clichetool: %s cannot be linked", e.fullpath); return false }
		}
		return true
	}
	if !link_all(real, CHECK_ROOT, "vendor") || !link_all(fmt.tprintf("%s/vendor", real), CHECK_ROOT + "/vendor", "wgpu") { return false }
	sources, err := os.read_all_directory_by_path(fmt.tprintf("%s/vendor/wgpu", real), context.temp_allocator)
	if err != nil { fmt.eprintln("clichetool: Odin's vendor/wgpu cannot be read"); return false }
	for e in sources {
		if !strings.has_suffix(e.name, ".odin") { continue }
		if os.copy_file(fmt.tprintf("%s/%s", wgpu, e.name), e.fullpath) != nil { fmt.eprintfln("clichetool: %s cannot be copied", e.fullpath); return false }
	}
	lib := fmt.tprintf("%s/%s", wgpu, WGPU_WINDOWS_LIB)
	_ = os.make_directory_all(lib[:strings.last_index_byte(lib, '/')])
	if os.write_entire_file(lib, []u8{}) != nil { fmt.eprintfln("clichetool: %s cannot be written", lib); return false }
	return true
}

// The settings' pages, drawn offscreen by a build of the program with CLICHE_SHOTS (src/shots.odin): no window opens.
run_shots :: proc(args: []string) -> int {
	folder := len(args) > 0 ? args[0] : "build/shots"
	if !build_text() { return 1 }
	_ = os.make_directory_all(folder)
	out := fmt.tprintf("build/cliche-shots%s", ODIN_OS == .Windows ? ".exe" : "")
	if !toolbox.run(odin_cmd("build", "src", {fmt.tprintf("-out:%s", out), "-debug", "-o:none", fmt.tprintf("-define:CLICHE_SHOTS=%s", folder)}), {echo = true}) { return 1 }
	return toolbox.run({out}, {echo = true}) ? 0 : 1
}
