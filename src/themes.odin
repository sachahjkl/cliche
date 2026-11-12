package cliche

// cliche's own theme, first of the list: the colours of its logo, a night blue for the surfaces (the lens) and a coral
// accent (the corners of the selection). Then the toolkit's themes (gui_toolkit docs/themes.md).

import "gt:ui"

THEME_CLICHE :: ui.Theme_Def{"cliche",
	// dark: surfaces, text (faint to strong), hues (accent, blue, purple, green, yellow, red, teal, pink)
	{{0x0d0e15ff, 0x12131cff, 0x181a25ff, 0x181a25ff, 0x21243aff, 0x2a2e45ff}, {0x5a5d70ff, 0x8a8ea3ff, 0xe8e9f0ff, 0xffffffff},
		{0xff8a5bff, 0x8fa2ffff, 0xa99bc4ff, 0x46a758ff, 0xf5a524ff, 0xe5484dff, 0x7cc4cfff, 0xe58fb0ff}},
	// light
	{{0xe9eaf0ff, 0xf4f5f9ff, 0xffffffff, 0xffffffff, 0xecedf3ff, 0xdcdee8ff}, {0x9a9db0ff, 0x676a7dff, 0x1a1b25ff, 0x000000ff},
		{0xd9532eff, 0x4c5bd4ff, 0x6b56a3ff, 0x2f8f46ff, 0xc98a10ff, 0xd93d42ff, 0x2f7c86ff, 0xa64a72ff}},
	.Both, nil, false, 0}

// The themes the settings can show: cliche's, then the toolkit's.
themes :: proc() -> []ui.Theme_Def {
	@(static) list: [len(ui.THEMES) + 1]ui.Theme_Def
	if list[0].name == "" {
		list[0] = THEME_CLICHE
		copy(list[1:], ui.THEMES[:])
	}
	return list[:]
}
