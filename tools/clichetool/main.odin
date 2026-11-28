// clichetool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/clichetool -collection:gt=ext/gui_toolkit/src -out:build/clichetool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library on Linux).
// GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package clichetool

import tk_changelog "gt:changelog"
import cli "gt:cli"
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
	{toolbox.NOTICES_FILE, toolbox.NOTICES_FILE},
}

project :: proc() -> toolbox.Project {
	return {
		name = "cliche", repository = "https://github.com/sachahjkl/cliche", changelog = "CHANGELOG.md",
		version_file = "src/main.odin", version_line = "APP_VERSION :: ", program = PROGRAM,
		linux_defines = LINUX_DEFINES[:],
		// (a release has only the icons cliche names: lucide.<NAME> constants everywhere; WebP on Windows: its export)
		features = {.Lucide_Subset, .Webp},
		// (what Windows shows of it: src/integration.odin's identity says the same)
		title = "cliche", description = "Screenshots and screen recorder",
		publisher = "Froment Software", copyright = "Copyright (c) 2026 sachahjkl",
	}
}

// The `licence` and `paddle` commands: cliche's licence (src/licence.odin), its development pair, its Paddle catalogue.
LICENCE_TOOL :: toolbox.Licence_Tool{
	product  = cliche_licence.PRODUCT,
	// (the development pair's private key, public on purpose: "cliche-dev-licence-test-seed-01!")
	dev_seed = "Y2xpY2hlLWRldi1saWNlbmNlLXRlc3Qtc2VlZC0wMSE",
	hint     = "Open Cliche's settings, the General page, Licence: choose this file, or paste the key there.",
	paddle   = {name = "Cliche User License", description = "A personal, perpetual licence of cliche, the screenshot and screen-recording tool.", amounts = "supporter=1500", currency = "EUR"},
}

main :: proc() {
	p := project()
	// (update: the release has the program alone and its manifest, signed by $UPDATE_SIGNING_KEY: what installed copies
	// update themselves from)
	r := release.commands({project = p, dist = "build/dist", files = DIST_FILES[:], check = proc() -> cli.Exit { return toolbox.ended(toolbox.program_check(build_options())) }, update = cliche_update.PRODUCT})
	l := toolbox.licence_commands(LICENCE_TOOL)
	b := toolbox.build_commands(build_options())
	toolbox.tool_main("clichetool", {
		b[0], b[1], b[2],
		{name = "shots", usage = "[folder [window...]]: (window: settings, editor, history, workflows, record, or motion: the Workflows mode frame by frame) the windows drawn offscreen, as PNG files (default build/shots)", run = run_shots},
		toolbox.logo_command(logo()),
		tk_changelog.command(p),
		toolbox.i18n_command(I18N),
		site_command(),
		toolbox.notices_command(p),
		toolbox.Command{name = "update", usage = "keygen <file> | pubkey | manifest <program> <version> - <out> | verify <manifest> -: cliche's update key and manifests", run = proc(args: []string) -> cli.Exit { return toolbox.update_command(cliche_update.PRODUCT, args) }},
		r[0], r[1], r[2],
		l[0], l[1],
	}, toolbox.ROOT_MARK_DEFAULT)
}

////////////////////////////////
// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release.
// {{version}} in the home page is the last version: its download links name the files of that release.

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
	m := tk_site.meta_default("Cliche", "https://cliche.froment.software/", "https://github.com/sachahjkl/cliche", "Screenshots and screen recorder", "#0e0f14", "#ef8a5a", card = "img/editor.png")
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
	name           = "Cliche",
	icon           = "../img/logo.png",
	product_title  = "Cliche User License",
	price          = "15&nbsp;&euro;",
	price_note     = "",
	environment    = "production",
	client_token   = "live_94fe083b50757639ed26ec5ca77",   // Paddle's client-side token (public: it is in the page)
	edition        = "supporter",
	price_id       = "pri_01m7fyasmyjra4t0qsx91zpaxx",
	worker         = "https://cliche-licence.sacha-42a.workers.dev",
	thanks         = "https://cliche.froment.software/thanks/",
	help           = "https://github.com/sachahjkl/cliche/issues/new",
	register       = "Open Cliche's settings (Ctrl+,), the <b>General</b> page, <b>Licence</b>: paste the key, or choose the file.",
	extension      = ".clichelicence",
	repository     = "https://github.com/sachahjkl/cliche",
	seller         = tk_site.SELLER_FROMENT,
	code_licence   = "MIT License",
	platform       = "Linux, x64 (Wayland), and Windows 10 or 11, x64.",
	network        = "Cliche connects to the network only when you ask it to: the <em>Upload</em> action sends the picture to the host you chose, by default Litterbox, catbox.moe's host of temporary files, which deletes it after 72 hours. That host receives the picture under its own terms.",
	stylesheet     = "../style.css",
	home           = "../",
	updated        = "2026-11-13",
}

// The site's command: the toolkit's, the shop's pages among the others (Meta.shop).
@(private = "file")
site_command :: proc() -> toolbox.Command {
	return tk_site.command({meta = site_meta(), pages = {version_mark = "{{version}}", downloads = SITE_DOWNLOADS[:]}, images = tk_site.images_default()})
}
