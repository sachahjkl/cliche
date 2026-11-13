package cliche

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import flowgraph "gt:flowgraph"

@(private = "file")
add :: proc(g: ^flowgraph.Graph, kind: Node_Kind) -> ^flowgraph.Node {
	return flowgraph.graph_node(g, flowgraph.node_add(g, &CATALOG, int(kind), {}))
}

@(private = "file")
param :: proc(n: ^flowgraph.Node, name: string) -> ^flowgraph.Param {
	return flowgraph.param(&CATALOG, n, name)
}

@(test)
the_file_gives_back_the_workflows :: proc(t: ^testing.T) {
	ws := workflows_default()
	defer workflows_free(&ws)
	// a few parameters away from their defaults, with a text that needs escaping
	wf := &ws.set.list[0]
	resize := add(&wf.graph, .Resize)
	resize.pos = {10.5, -20}
	param(resize, "percent").number = 33
	param(resize, "filter").number = 2
	mark := add(&wf.graph, .Watermark)
	text := param(mark, "text")
	delete(text.text)
	text.text = strings.clone("say \"hi\"\n\\ ok")
	param(mark, "color").color = {1, 2, 3, 4}
	old := wf.name
	wf.name = strings.concatenate({old, " é"})
	delete(old)

	file := workflows_text(&ws)
	defer delete(file)
	// (cliche's own keys: the users' files keep reading)
	testing.expect(t, strings.contains(file, `"workflows": [`))
	testing.expect(t, strings.contains(file, `"triggers": ["region", "screen", "window"]`))
	back, why := workflows_parse(file)
	defer workflows_free(&back)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(back.set.list), len(ws.set.list))
	for &a, i in ws.set.list {
		b := &back.set.list[i]
		testing.expect_value(t, b.id, a.id)
		testing.expect_value(t, b.name, a.name)
		testing.expect_value(t, workflow_triggers(b), workflow_triggers(&a))
		testing.expect_value(t, len(b.graph.nodes), len(a.graph.nodes))
		testing.expect_value(t, len(b.graph.links), len(a.graph.links))
		for na, j in a.graph.nodes {
			nb := b.graph.nodes[j]
			testing.expect_value(t, nb.id, na.id)
			testing.expect_value(t, nb.kind, na.kind)
			testing.expect_value(t, nb.pos, na.pos)
			for p, k in na.params {
				testing.expect_value(t, nb.params[k].number, p.number)
				testing.expect_value(t, nb.params[k].text, p.text)
				testing.expect_value(t, nb.params[k].color, p.color)
			}
		}
		for l, j in a.graph.links { testing.expect_value(t, b.graph.links[j], l) }
	}
}

@(test)
what_the_file_gets_wrong_is_dropped :: proc(t: ^testing.T) {
	file := `{"version": 1, "workflows": [
		{"id": 4, "name": "A", "triggers": ["region", "nothing"], "nodes": [
			{"id": 1, "kind": "capture", "x": 0, "y": 0},
			{"id": 2, "kind": "teleport", "x": 0, "y": 0},
			{"id": 3, "kind": "save_file", "x": 0, "y": 0, "params": {"format": 1, "unknown": 3}},
			{"id": 4, "kind": "read_qr", "x": 0, "y": 0}],
		 "links": [{"from": 1, "from_port": 0, "to": 3, "to_port": 0}, {"from": 3, "from_port": 0, "to": 4, "to_port": 0},
		           {"from": 1, "from_port": 0, "to": 2, "to_port": 0}]},
		{"id": 4, "name": "B", "triggers": ["region", "screen"], "nodes": [], "links": []}]}`
	ws, why := workflows_parse(file)
	defer workflows_free(&ws)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(ws.set.list), 2)
	a, b := &ws.set.list[0], &ws.set.list[1]
	testing.expect_value(t, len(a.graph.nodes), 3)                    // (the unknown kind is dropped)
	testing.expect_value(t, len(a.graph.links), 1)                    // (a file into a picture's port, a link to nothing)
	testing.expect_value(t, workflow_triggers(a), Trigger_Set{.Region})
	testing.expect_value(t, len(a.labels), 1)                         // (a word that names no trigger goes)
	testing.expect_value(t, workflow_triggers(b), Trigger_Set{.Screen})   // (region runs A: the first that names it)
	testing.expect(t, b.id != a.id)                                   // (an id taken twice gets a new one)
	testing.expect_value(t, flowgraph.param_int(&CATALOG, &a.graph.nodes[1], "format"), 1)
	testing.expect_value(t, a.graph.next_id, 4)
}

@(test)
a_broken_or_missing_file_gives_the_defaults :: proc(t: ^testing.T) {
	_, why := workflows_parse("{not json")
	testing.expect(t, why != "")
	_, why = workflows_parse(`{"version": 99, "workflows": []}`)
	testing.expect(t, why != "")

	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil { return }
	path := strings.concatenate({dir, "/cliche-test-workflows.json"}, context.temp_allocator)
	aside := strings.concatenate({path, ".broken"}, context.temp_allocator)
	defer { _ = os.remove(path); _ = os.remove(aside) }
	_ = os.remove(path)

	missing, problem := workflows_load_from(path)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(missing.set.list), 4)
	workflows_free(&missing)

	_ = os.write_entire_file(path, "[1, 2")
	broken, why_broken := workflows_load_from(path)
	defer delete(why_broken)
	testing.expect(t, why_broken != "")
	testing.expect_value(t, len(broken.set.list), 4)
	testing.expect(t, os.exists(aside))   // (kept aside, not lost)
	testing.expect(t, !os.exists(path))
	workflows_free(&broken)
}

@(test)
the_defaults_bind_each_trigger_once :: proc(t: ^testing.T) {
	ws := workflows_default()
	defer workflows_free(&ws)
	testing.expect_value(t, workflows_unbound(&ws), Trigger_Set{})
	for tr in Trigger {
		count := 0
		for &wf in ws.set.list { if tr in workflow_triggers(&wf) { count += 1 } }
		testing.expect_value(t, count, 1)
	}
	// moving a trigger leaves the workflow that had it
	screenshot := workflows_for(&ws, .Region)
	qr := workflows_for(&ws, .Qr)
	workflows_bind(&ws, qr.id, .Region, true)
	testing.expect(t, workflows_for(&ws, .Region) == qr)
	testing.expect(t, .Region not_in workflow_triggers(screenshot))
}

@(test)
an_edit_keeps_the_graph_valid :: proc(t: ^testing.T) {
	g: flowgraph.Graph
	defer flowgraph.graph_destroy(&g)
	node :: proc(g: ^flowgraph.Graph, kind: Node_Kind) -> u64 { return flowgraph.node_add(g, &CATALOG, int(kind), {}) }
	capture := node(&g, .Capture)
	testing.expect_value(t, node(&g, .Capture), 0)   // (one Capture: its max_count)
	a := node(&g, .Blur)
	b := node(&g, .Sepia)
	save := node(&g, .Save_File)
	copy_text := node(&g, .Copy_Text)
	_, ok := flowgraph.link(&g, &CATALOG, {capture, 0, a, 0})
	testing.expect(t, ok)
	_, ok = flowgraph.link(&g, &CATALOG, {a, 0, b, 0})
	testing.expect(t, ok)
	_, ok = flowgraph.link(&g, &CATALOG, {b, 0, a, 0})
	testing.expect(t, !ok)                                       // (a loop)
	_, ok = flowgraph.link(&g, &CATALOG, {save, 0, copy_text, 0})
	testing.expect(t, ok)                                        // (a file's path is a text)
	_, ok = flowgraph.link(&g, &CATALOG, {capture, 0, copy_text, 0})
	testing.expect(t, !ok)                                       // (a picture is not)
	_, ok = flowgraph.link(&g, &CATALOG, {capture, 0, save, 1})
	testing.expect(t, !ok)                                       // (nor is it an action)
	replaced, linked := flowgraph.link(&g, &CATALOG, {capture, 0, b, 0})
	testing.expect(t, linked)
	testing.expect_value(t, replaced.?, flowgraph.Link{a, 0, b, 0})   // (an input takes one link)
	deleted := [2]u64{capture, a}
	testing.expect_value(t, flowgraph.nodes_delete(&g, &CATALOG, deleted[:]), 1)   // (Capture stays: its min_count)
	for l in g.links { testing.expect(t, l.from_node != a && l.to_node != a) }
}

// The catalog's kinds are in Node_Kind's order, each named as the file names it.
@(test)
the_catalog_follows_the_node_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CATALOG.nodes), len(Node_Kind))
	for k in Node_Kind {
		if int(k) >= len(CATALOG.nodes) { break }
		testing.expect_value(t, CATALOG.nodes[int(k)].name, strings.to_lower(fmt.tprint(k), context.temp_allocator))
	}
}

@(test)
a_node_says_what_it_does :: proc(t: ^testing.T) {
	g: flowgraph.Graph
	defer flowgraph.graph_destroy(&g)
	check :: proc(t: ^testing.T, g: ^flowgraph.Graph, kind: Node_Kind, want: string, set: proc(n: ^flowgraph.Node) = nil, loc := #caller_location) {
		n := add(g, kind)
		if set != nil { set(n) }
		testing.expect_value(t, node_summary(n), want, loc = loc)
	}
	check(t, &g, .Resize, "50 %")
	check(t, &g, .Resize, "at most 1920 × 1080 px", proc(n: ^flowgraph.Node) { param(n, "mode").number = 1 })
	check(t, &g, .Crop, "0 px each side")
	check(t, &g, .Rotate, "90° right")
	check(t, &g, .Border, "4 px #000000")
	check(t, &g, .Pad, "32 px, transparent")
	check(t, &g, .Blur, "4 px")
	check(t, &g, .Hue, "+30°")
	check(t, &g, .Save_File, "PNG to the default folder")
	check(t, &g, .Save_File, "PNG (fast) to …/Pictures/shots", proc(n: ^flowgraph.Node) {
		param(n, "folder").text = strings.clone("/home/ada/Pictures/shots")
		param(n, "format").number = 1
	})
	check(t, &g, .Upload, "to the default host")
	check(t, &g, .Condition, "width > 1920")
	check(t, &g, .Watermark, "\"cliche\", bottom right")
	check(t, &g, .Copy_Image, "")
	// (a value out of its range, as a hand-edited file may hold, is read clamped)
	check(t, &g, .Threshold, "level 255", proc(n: ^flowgraph.Node) { param(n, "level").number = 9000 })
}
