package cliche

import "core:strings"
import "core:testing"

// Every preference has its line in docs/configuration.md: a setting nobody can read about does not exist for the user.
@(test)
every_preference_is_documented :: proc(t: ^testing.T) {
	doc := string(#load("../docs/configuration.md"))
	for d in PREF_DEFS {
		testing.expectf(t, strings.contains(doc, strings.concatenate({"| `", d.name, "` |"}, context.temp_allocator)), "%s is in docs/configuration.md", d.name)
	}
}
