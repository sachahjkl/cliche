package clichetool

// A release, with the toolkit's steps (gt:release):
//   notes <version>              the changelog's section of that version (the notes of its GitHub release)
//   ship <version> [--dry-run]   from a clean master: the fragments of changelog.d/ assembled into [<version>] with
//                                today's date, APP_VERSION set, a commit, the tag v<version>, the push; the site follows

import release "gt:release"

CHANGELOG    :: "CHANGELOG.md"
VERSION_FILE :: "src/main.odin"
VERSION_LINE :: "APP_VERSION :: "
REPOSITORY   :: "https://github.com/sachahjkl/cliche"

release_config :: proc() -> release.Config {
	return {
		name = "cliche", repository = REPOSITORY, changelog = CHANGELOG, version_file = VERSION_FILE, version_line = VERSION_LINE,
		check = proc() -> int { return run_check(nil) },
	}
}

run_ship :: proc(args: []string) -> int { return release.ship(release_config(), args) }

run_notes :: proc(args: []string) -> int { return release.notes(release_config(), args) }
