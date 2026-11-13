// clichetool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library on Linux).
// GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package clichetool

import tk_changelog "gt:changelog"
import release "gt:release"
import tk_site "gt:site"
import toolbox "gt:toolbox"

when ODIN_OS == .Windows {
	PROGRAM :: "build/cliche.exe"
} else {
	PROGRAM :: "build/cliche"
}

// What a build on Linux needs: the toolkit's native text backend.
@(rodata)
LINUX_DEFINES := [?]string{"-define:FONT_BACKEND=native"}

// What goes beside the program in a release's archive: the file, and its name there.
@(rodata)
DIST_FILES := [?][2]string{
	{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"CHANGELOG.md", "CHANGELOG.md"},
	{"ext/gui_toolkit/src/lucide/LICENSE.txt", "LUCIDE-LICENSE.txt"},
}

project :: proc() -> toolbox.Project {
	return {
		name = "cliche", repository = "https://github.com/sachahjkl/cliche", changelog = "CHANGELOG.md",
		version_file = "src/main.odin", version_line = "APP_VERSION :: ", program = PROGRAM,
		linux_defines = LINUX_DEFINES[:],
	}
}

main :: proc() {
	p := project()
	r := release.commands({project = p, dist = "build/dist", files = DIST_FILES[:], check = proc() -> int { return run_check(nil) }})
	toolbox.tool_main("clichetool", {
		{name = "build", usage = "[release]: the toolkit's text library when its sources changed, then build/cliche", run = run_build},
		{name = "test", usage = ": the tests of the program", run = run_test},
		{name = "check", usage = ": odin check of the program for this system and for Windows, and of this tool (-vet), the ui scopes, the changelog's fragments, the tests, then a release build", run = run_check},
		{name = "shots", usage = "[folder [window...]]: (window: settings, editor, history, workflows, record, or motion: the Workflows mode frame by frame) the windows drawn offscreen, as PNG files (default build/shots)", run = run_shots},
		toolbox.logo_command(logo()),
		tk_changelog.command(p),
		tk_site.command({meta = site_meta(), pages = {version_mark = "{{version}}", downloads = SITE_DOWNLOADS[:]}}),
		toolbox.notices_command(p),
		r[0], r[1], r[2],
	}, toolbox.ROOT_MARK_DEFAULT)
}

////////////////////////////////
// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release.
// {{version}} in the home page is the last version: its download links name the files of that release.

SITE_META :: tk_site.Meta{
	url         = "https://cliche.froment.software/",
	name        = "cliche",
	repository  = "https://github.com/sachahjkl/cliche",
	tagline     = "Fast screenshots and screen recordings, shared at once",
	changes     = "CHANGELOG.md",
	card        = "img/editor.png",
	logo        = "img/logo.png",
	logo_file   = "site/img/logo.png",
	theme       = "#0e0f14",
	accent      = "#ef8a5a",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareApplication",
	root_domain = false,   // (github.io answers for /robots.txt and /favicon.ico, not the site)
}

@(rodata)
SITE_LD := [?][2]string{
	{"applicationCategory", "MultimediaApplication"},
	{"operatingSystem", "Linux, Windows"},
	{"license", "https://opensource.org/license/mit"},
}

// The home page's download button, one per system the release workflow builds for (the reader's shown).
@(rodata)
SITE_DOWNLOADS := [?]tk_site.Download{
	{os = "linux", label = "Linux", href = "https://github.com/sachahjkl/cliche/releases/download/v{{version}}/cliche-{{version}}-linux-x64.tar.gz", detail = "v{{version}} · x64 · .tar.gz · Wayland"},
	{os = "windows", label = "Windows", href = "https://github.com/sachahjkl/cliche/releases/download/v{{version}}/cliche-{{version}}-windows-x64.zip", detail = "v{{version}} · Windows 10 / 11 · x64 · .zip"},
}

@(private = "file")
site_meta :: proc() -> tk_site.Meta {
	m := SITE_META
	m.ld_fields = SITE_LD[:]
	return m
}
