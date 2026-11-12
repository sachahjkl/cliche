package clichetool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site); this file says what this site is: its address, names and colours.
//   site build <site> <out>      the changelog's pages and the classic ones from <site>, then what a page says when it is
//                                shared; <out> is what is published
//   site check [--site folder] [--shot file.png] [--browser program]
//                                the pages in a real browser, served on this machine
// {{version}} in the home page is the last version.

import "core:fmt"
import tk_site "gt:site"

SITE_DIR     :: "site"
VERSION_MARK :: "{{version}}"

// Where the site is published, what it is: the one place that says it.
SITE_META :: tk_site.Meta{
	url         = "https://cliche.froment.software/",
	name        = "cliche",
	repository  = REPOSITORY,
	tagline     = "Fast screenshots and screen recordings, shared at once",
	changes     = CHANGELOG,
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

SITE_LD :: [?][2]string{
	{"applicationCategory", "MultimediaApplication"},
	{"operatingSystem", "Linux, Windows"},
	{"license", "https://opensource.org/license/mit"},
}

@(private = "file")
site_meta :: proc() -> tk_site.Meta {
	m := SITE_META
	ld := SITE_LD
	m.ld_fields = make([][2]string, len(ld), context.temp_allocator)
	copy(m.ld_fields, ld[:])
	return m
}

@(private = "file")
site_changelog :: proc(site, out: string) -> bool {
	return tk_site.build_changelog(site, out, {changes = CHANGELOG, version_mark = VERSION_MARK})
}

run_site :: proc(args: []string) -> int {
	what := len(args) > 0 ? args[0] : ""
	switch what {
	case "build":
		if len(args) != 3 { break }
		if !site_changelog(args[1], args[2]) { return 1 }
		return tk_site.build_meta(site_meta(), args[2], args[2]) ? 0 : 1
	case "check":
		o := tk_site.Check_Options{site = SITE_DIR, generate = site_changelog}
		if why := tk_site.check_arguments(args[1:], &o); why != "" { fmt.eprintfln("clichetool site check: %s", why); return EXIT_USAGE }
		return tk_site.check(o) ? 0 : 1
	}
	fmt.eprintln("clichetool site build <site> <out> | check [--site folder] [--shot file.png] [--browser program]")
	return EXIT_USAGE
}
