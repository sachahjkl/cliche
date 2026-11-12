package clichetool

// A release, the same steps on a laptop and in the release workflow (.github/workflows/release.yml), with the toolkit's
// (gt:release):
//   package [version]            build/dist: cliche-<version>-linux-x64.tar.gz or -windows-x64.zip (the program, its
//                                licence, Lucide's, the README and the changelog) and its SHA-256; a version given must be
//                                APP_VERSION
//   notes <version>              the changelog's section of that version (the notes of its GitHub release)
//   ship <version> [--dry-run]   from a clean master: the fragments of changelog.d/ assembled into [<version>] with
//                                today's date, APP_VERSION set, a commit, the tag v<version>, the push. The release
//                                workflow builds the archives on the tag and publishes them; the site follows

import release "gt:release"

CHANGELOG    :: "CHANGELOG.md"
VERSION_FILE :: "src/main.odin"
VERSION_LINE :: "APP_VERSION :: "
REPOSITORY   :: "https://github.com/sachahjkl/cliche"

// What goes beside the program in the archive: the file, and its name there.
@(rodata)
DIST_FILES := [?][2]string{
	{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"CHANGELOG.md", "CHANGELOG.md"},
	{"ext/gui_toolkit/src/lucide/LICENSE.txt", "LUCIDE-LICENSE.txt"},
}

release_config :: proc() -> release.Config {
	return {
		name = "cliche", repository = REPOSITORY, changelog = CHANGELOG, version_file = VERSION_FILE, version_line = VERSION_LINE,
		check = proc() -> int { return run_check(nil) },
		program = PROGRAM, dist = "build/dist", files = DIST_FILES[:],
	}
}

run_package :: proc(args: []string) -> int { return release.package_(release_config(), args) }

run_ship :: proc(args: []string) -> int { return release.ship(release_config(), args) }

run_notes :: proc(args: []string) -> int { return release.notes(release_config(), args) }
