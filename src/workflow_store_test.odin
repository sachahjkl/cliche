package cliche

import "core:os"
import "core:strings"
import "core:testing"

@(test)
the_file_gives_back_the_workflows :: proc(t: ^testing.T) {
	ws := workflows_default()
	defer workflows_free(&ws)
	// a few parameters away from their defaults, with a text that needs escaping
	wf := &ws.list[0]
	resize := workflow_node_add(wf, .Resize, {10.5, -20})
	n := workflow_node(wf, resize)
	percent, filter := node_param(n, "percent"), node_param(n, "filter")
	percent.number = 33
	filter.number = 2
	mark := workflow_node_add(wf, .Watermark, {0, 300})
	text := node_param(workflow_node(wf, mark), "text")
	delete(text.text)
	text.text = strings.clone("say \"hi\"\n\\ ok")
	tint := node_param(workflow_node(wf, mark), "color")
	tint.color = {1, 2, 3, 4}
	old := wf.name
	wf.name = strings.concatenate({old, " é"})
	delete(old)

	file := workflows_text(&ws)
	defer delete(file)
	back, why := workflows_parse(file)
	defer workflows_free(&back)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(back.list), len(ws.list))
	for &a, i in ws.list {
		b := &back.list[i]
		testing.expect_value(t, b.id, a.id)
		testing.expect_value(t, b.name, a.name)
		testing.expect_value(t, b.triggers, a.triggers)
		testing.expect_value(t, len(b.nodes), len(a.nodes))
		testing.expect_value(t, len(b.links), len(a.links))
		for na, j in a.nodes {
			nb := b.nodes[j]
			testing.expect_value(t, nb.id, na.id)
			testing.expect_value(t, nb.kind, na.kind)
			testing.expect_value(t, nb.pos, na.pos)
			for p, k in na.params {
				testing.expect_value(t, nb.params[k].number, p.number)
				testing.expect_value(t, nb.params[k].text, p.text)
				testing.expect_value(t, nb.params[k].color, p.color)
			}
		}
		for l, j in a.links { testing.expect_value(t, b.links[j], l) }
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
	testing.expect_value(t, len(ws.list), 2)
	a, b := &ws.list[0], &ws.list[1]
	testing.expect_value(t, len(a.nodes), 3)                       // (the unknown kind is dropped)
	testing.expect_value(t, len(a.links), 1)                       // (a file into a picture's port, a link to nothing)
	testing.expect_value(t, a.triggers, Trigger_Set{.Region})
	testing.expect_value(t, b.triggers, Trigger_Set{.Screen})      // (region runs A: the first that names it)
	testing.expect(t, b.id != a.id)                                // (an id taken twice gets a new one)
	testing.expect_value(t, node_int(&a.nodes[1], "format"), 1)
	testing.expect_value(t, a.next_id, 4)
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
	testing.expect_value(t, len(missing.list), 4)
	workflows_free(&missing)

	_ = os.write_entire_file(path, "[1, 2")
	broken, why_broken := workflows_load_from(path)
	defer delete(why_broken)
	testing.expect(t, why_broken != "")
	testing.expect_value(t, len(broken.list), 4)
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
		for wf in ws.list { if tr in wf.triggers { count += 1 } }
		testing.expect_value(t, count, 1)
	}
	// moving a trigger leaves the workflow that had it
	screenshot := workflows_for(&ws, .Region)
	qr := workflows_for(&ws, .Qr)
	workflows_bind(&ws, qr.id, .Region, true)
	testing.expect(t, workflows_for(&ws, .Region) == qr)
	testing.expect(t, .Region not_in screenshot.triggers)
}

@(test)
an_edit_keeps_the_graph_valid :: proc(t: ^testing.T) {
	wf: Workflow
	defer workflow_free(&wf)
	capture := workflow_node_add(&wf, .Capture, {})
	testing.expect_value(t, workflow_node_add(&wf, .Capture, {}), 0)   // (one Capture)
	a := workflow_node_add(&wf, .Blur, {})
	b := workflow_node_add(&wf, .Sepia, {})
	save := workflow_node_add(&wf, .Save_File, {})
	copy_text := workflow_node_add(&wf, .Copy_Text, {})
	_, ok := workflow_link(&wf, {capture, 0, a, 0})
	testing.expect(t, ok)
	_, ok = workflow_link(&wf, {a, 0, b, 0})
	testing.expect(t, ok)
	_, ok = workflow_link(&wf, {b, 0, a, 0})
	testing.expect(t, !ok)                                       // (a loop)
	_, ok = workflow_link(&wf, {save, 0, copy_text, 0})
	testing.expect(t, ok)                                        // (a file's path is a text)
	_, ok = workflow_link(&wf, {capture, 0, copy_text, 0})
	testing.expect(t, !ok)                                       // (a picture is not)
	replaced, linked := workflow_link(&wf, {capture, 0, b, 0})
	testing.expect(t, linked)
	testing.expect_value(t, replaced.?, Workflow_Link{a, 0, b, 0})   // (an input takes one link)
	deleted := [2]u64{capture, a}
	testing.expect_value(t, workflow_nodes_delete(&wf, deleted[:]), 1)   // (Capture stays)
	for l in wf.links { testing.expect(t, l.from_node != a && l.to_node != a) }
}

@(test)
a_node_says_what_it_does :: proc(t: ^testing.T) {
	wf: Workflow
	defer workflow_free(&wf)
	check :: proc(t: ^testing.T, wf: ^Workflow, kind: Node_Kind, want: string, set: proc(n: ^Workflow_Node) = nil, loc := #caller_location) {
		n := workflow_node(wf, workflow_node_add(wf, kind, {}))
		if set != nil { set(n) }
		testing.expect_value(t, node_summary(n), want, loc = loc)
	}
	check(t, &wf, .Resize, "50 %")
	check(t, &wf, .Resize, "at most 1920 × 1080 px", proc(n: ^Workflow_Node) { p := node_param(n, "mode"); p.number = 1 })
	check(t, &wf, .Crop, "0 px each side")
	check(t, &wf, .Rotate, "90° right")
	check(t, &wf, .Border, "4 px #000000")
	check(t, &wf, .Pad, "32 px, transparent")
	check(t, &wf, .Blur, "4 px")
	check(t, &wf, .Hue, "+30°")
	check(t, &wf, .Save_File, "PNG to the default folder")
	check(t, &wf, .Save_File, "PNG (fast) to …/Pictures/shots", proc(n: ^Workflow_Node) {
		f := node_param(n, "folder")
		f.text = strings.clone("/home/ada/Pictures/shots")
		p := node_param(n, "format")
		p.number = 1
	})
	check(t, &wf, .Upload, "to the default host")
	check(t, &wf, .Condition, "width > 1920")
	check(t, &wf, .Watermark, "\"cliche\", bottom right")
	check(t, &wf, .Copy_Image, "")
	// (a value out of its range, as a hand-edited file may hold, is read clamped)
	check(t, &wf, .Threshold, "level 255", proc(n: ^Workflow_Node) { p := node_param(n, "level"); p.number = 9000 })
}
