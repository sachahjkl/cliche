package cliche

// The tray's icon, drawn at start: the four corners of a selection around a dot. No file to load, and it stays sharp at
// the size asked.

TRAY_ICON_SIZE :: 32

// `size` x `size` straight RGBA: white marks on transparency, with a dark edge so that they read on a light panel too.
tray_icon_rgba :: proc(size: int, allocator := context.allocator) -> []u8 {
	px := make([]u8, size * size * 4, allocator)
	put :: proc(px: []u8, size, x, y: int, c: [4]u8) {
		if x < 0 || y < 0 || x >= size || y >= size { return }
		c := c   // (a parameter is not addressable: a copy is)
		copy(px[(y * size + x) * 4:][:4], c[:])
	}
	edge := [4]u8{20, 20, 24, 255}
	ink := [4]u8{255, 255, 255, 255}
	arm := size * 3 / 8     // the length of a corner's arms
	thick := max(size / 10, 2)
	inset := size / 10
	far := size - 1 - inset
	// a corner: two arms from (cx, cy) towards the inside, drawn with an edge one pixel wider first
	for pass in 0 ..< 2 {
		grow := pass == 0 ? 1 : 0
		c := pass == 0 ? edge : ink
		for corner in 0 ..< 4 {
			cx := corner & 1 == 0 ? inset : far
			cy := corner & 2 == 0 ? inset : far
			dx := corner & 1 == 0 ? 1 : -1
			dy := corner & 2 == 0 ? 1 : -1
			for i in -grow ..< arm + grow {
				for t in -grow ..< thick + grow {
					put(px, size, cx + dx * i, cy + dy * t, c)
					put(px, size, cx + dx * t, cy + dy * i, c)
				}
			}
		}
	}
	// the dot in the middle
	r := size / 8
	mid := size / 2
	for y in -r - 1 ..= r + 1 {
		for x in -r - 1 ..= r + 1 {
			d := x * x + y * y
			if d <= r * r { put(px, size, mid + x, mid + y, ink) } else if d <= (r + 1) * (r + 1) { put(px, size, mid + x, mid + y, edge) }
		}
	}
	return px
}
