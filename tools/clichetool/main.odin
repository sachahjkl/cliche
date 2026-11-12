// clichetool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library on Linux).
// GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package clichetool

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

EXIT_USAGE :: 2
ROOT_MARK  :: "odin.version"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command{
	{name = "build", about = "[release]: the toolkit's text library when its sources changed, then build/cliche", run = run_build},
	{name = "test", about = "the tests of the program", run = run_test},
	{name = "check", about = "odin check of the program for this system and for Windows, and of this tool (-vet), the changelog's fragments, the tests, then a release build", run = run_check},
	{name = "logo", about = "assets/logo*.png and cliche.ico, drawn by the toolkit's paint package", run = run_logo},
	{name = "shots", about = "[folder]: the settings' pages, the editor, the history and the workflows drawn offscreen, as PNG files (default build/shots)", run = run_shots},
	{name = "changelog", about = "new <type> <text> | check | preview: the fragments of changelog.d/", run = run_changelog},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	if !os.exists(ROOT_MARK) {
		root, code := toolbox.capture({"git", "rev-parse", "--show-toplevel"})
		if code != 0 { fmt.eprintln("clichetool: not in the repository"); os.exit(EXIT_USAGE) }
		if os.set_working_directory(strings.trim_space(root)) != nil { fmt.eprintfln("clichetool: cannot work in %s", root); os.exit(EXIT_USAGE) }
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("clichetool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("clichetool <command> [arguments]")
	commands := COMMANDS
	for c in commands { fmt.printfln("  %-10s %s", c.name, c.about) }
}
