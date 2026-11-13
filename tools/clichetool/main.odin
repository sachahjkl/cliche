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
import cliche_licence "../../src/licence"
import cliche_update "../../src/update"

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
		// (a release has only the icons cliche names: lucide.<NAME> constants everywhere)
		features = {.Lucide_Subset},
		// (what Windows shows of it: src/integration.odin's identity says the same)
		title = "cliche", description = "Fast screenshots and screen recordings, shared at once.",
		publisher = "Froment Software", copyright = "Copyright (c) 2026 sachahjkl",
	}
}

// The `licence` and `paddle` commands: cliche's licence (src/licence.odin), its development pair, its Paddle catalogue.
LICENCE_TOOL :: toolbox.Licence_Tool{
	product  = cliche_licence.PRODUCT,
	// (the development pair's private key, public on purpose: "cliche-dev-licence-test-seed-01!")
	dev_seed = "Y2xpY2hlLWRldi1saWNlbmNlLXRlc3Qtc2VlZC0wMSE",
	hint     = "Open cliche's settings, the General page, Licence: choose this file, or paste the key there.",
	paddle   = {name = "Cliche User License", description = "A personal, perpetual licence of cliche, the screenshot and screen-recording tool.", amounts = "supporter=1500", currency = "EUR"},
}

main :: proc() {
	p := project()
	// (update: the release has the program alone and its manifest, signed by $UPDATE_SIGNING_KEY: what installed copies
	// update themselves from)
	r := release.commands({project = p, dist = "build/dist", files = DIST_FILES[:], check = proc() -> int { return run_check(nil) }, update = cliche_update.PRODUCT})
	l := toolbox.licence_commands(LICENCE_TOOL)
	toolbox.tool_main("clichetool", {
		{name = "build", usage = "[release]: the toolkit's text library when its sources changed, then build/cliche", run = run_build},
		{name = "test", usage = ": the tests of the program", run = run_test},
		{name = "check", usage = ": odin check of the program for this system and for Windows, and of this tool (-vet), the ui scopes, the changelog's fragments, the French catalogue, the tests, then a release build", run = run_check},
		{name = "shots", usage = "[folder [window...]]: (window: settings, editor, history, workflows, record, or motion: the Workflows mode frame by frame) the windows drawn offscreen, as PNG files (default build/shots)", run = run_shots},
		toolbox.logo_command(logo()),
		tk_changelog.command(p),
		toolbox.i18n_command({dirs = {"src"}, folder = "i18n"}),
		site_command(),
		toolbox.notices_command(p),
		toolbox.Command{name = "update", usage = "keygen <file> | pubkey | manifest <program> <version> - <out> | verify <manifest> -: cliche's update key and manifests", run = proc(args: []string) -> int { return toolbox.update_command(cliche_update.PRODUCT, args) }},
		r[0], r[1], r[2],
		l[0], l[1],
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
	publisher_logo = "img/froment-software-64.png",
	licence     = "MIT",
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
	m.shop = SHOP
	return m
}

////////////////////////////////
// The shop: cliche's licence (src/licence), sold through Paddle by the toolkit's licence Worker. Its pages (pricing,
// thanks, terms, refunds, privacy, imprint) are the toolkit's templates, filled at each `site build` (Meta.shop). What is empty is
// the maintainer's to give once the shop is set up (gui_toolkit docs/licence.md, "What the maintainer does at the end"):
// until the client token, the price id and the Worker are there, the button says "Coming soon".

SHOP :: tk_site.Shop{
	name           = "cliche",
	icon           = "../img/logo.png",
	product_title  = "Cliche User License",
	price          = "15&nbsp;&euro;",
	price_note     = "",
	environment    = "sandbox",
	edition        = "supporter",
	price_id       = "",
	thanks         = "https://cliche.froment.software/thanks/",
	help           = "https://github.com/sachahjkl/cliche/issues/new",
	register       = "Open cliche's settings (Ctrl+,), the <b>General</b> page, <b>Licence</b>: paste the key, or choose the file.",
	extension      = ".clichelicence",
	repository     = "https://github.com/sachahjkl/cliche",
	seller         = SELLER,
	code_licence   = "MIT License",
	platform       = "Linux, x64 (Wayland), and Windows 10 or 11, x64.",
	network        = "cliche connects to the network only when you ask it to: the <em>Upload</em> action sends the picture to the host you chose, by default Litterbox, catbox.moe's host of temporary files, which deletes it after 72 hours. That host receives the picture under its own terms.",
	stylesheet     = "../style.css",
	home           = "../",
	updated        = "2026-11-13",
}

// The seller, as Wren's imprint names it: the same block in every program of Froment Software.
SELLER :: tk_site.Seller{
	name       = "Froment Software",
	owner      = "Sacha Froment",
	status     = "sole proprietor (<em>entrepreneur individuel</em>)",
	address    = "7 Lieu-dit les Renardi&egrave;res, 72220 Marign&eacute;-Laill&eacute;, France",
	email      = "contact@froment.software",
	url        = "https://froment.software",
	siren      = "131 941 718",
	siret      = "131 941 718 00010",
	ape        = "6201Z, computer programming",
	registry   = "the French national register of companies (RNE)",
	registered = "23 October 2026",
	vat        = "not applicable, article 293 B of the French General Tax Code (<em>franchise en base de TVA</em>)",
}

// The site's command: the toolkit's, the shop's pages among the others (Meta.shop).
@(private = "file")
site_command :: proc() -> toolbox.Command {
	return tk_site.command({meta = site_meta(), pages = {version_mark = "{{version}}", downloads = SITE_DOWNLOADS[:]}})
}
