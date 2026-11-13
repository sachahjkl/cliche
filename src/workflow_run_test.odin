package cliche

import "core:slice"
import "core:strings"
import "core:testing"
import flowgraph "gt:flowgraph"

// A picture of `w` × `h` pixels, grey (owned).
@(private = "file")
picture :: proc(w, h: int) -> Shot {
	rgba := make([]u8, w * h * 4)
	for &b in rgba { b = 128 }
	return {rgba = rgba, size = {w, h}, source = .Region, scale = 1}
}

// A graph of `kinds` (Capture first), linked port 0 to port 0 by `links` (places in `kinds`). The node ids are the
// places plus one.
@(private = "file")
graph :: proc(kinds: []Node_Kind, links: [][2]int) -> (g: flowgraph.Graph) {
	for k, i in kinds { flowgraph.node_add(&g, &CATALOG, int(k), {f32(i) * 200, 0}) }
	for l in links { flowgraph.link(&g, &CATALOG, {u64(l[0] + 1), 0, u64(l[1] + 1), 0}) }
	return
}

@(private = "file")
ids :: proc(tasks: []flowgraph.Task) -> []u64 {
	out := make([]u64, len(tasks), context.temp_allocator)
	for t, i in tasks { out[i] = t.id }
	return out
}

@(private = "file")
state :: proc(run: ^Run, node: int) -> flowgraph.Node_State {
	return run.flow.nodes[node].state
}

// The picture that came into a task (nil: none).
@(private = "file")
input_shot :: proc(task: flowgraph.Task) -> ^Shot {
	v, _ := flowgraph.task_input(task, 0)
	d := run_data(v)
	return d != nil ? &d.shot : nil
}

// A node's work done, with a new picture (a transform's) on its output.
@(private = "file")
done_with_picture :: proc(run: ^Run, node: int, w, h: int) -> bool {
	r: flowgraph.Result
	r.outputs[0] = run_value(PORT_IMAGE, {shot = picture(w, h)})
	return flowgraph.run_finish(&run.flow, node, r)
}

@(private = "file")
done_with_text :: proc(run: ^Run, node: int, kind: flowgraph.Port_Kind, text: string, origin: Node_Kind) -> bool {
	r: flowgraph.Result
	r.outputs[0] = run_value(kind, {text = strings.clone(text), origin = origin})
	return flowgraph.run_finish(&run.flow, node, r)
}

@(test)
nodes_run_in_the_order_of_their_links :: proc(t: ^testing.T) {
	g := graph({.Capture, .Resize, .Save_File}, {{0, 1}, {1, 2}})
	defer flowgraph.graph_free(&g)
	run: Run
	run_start(&run, g, picture(4, 4), {id = 1})
	defer run_free(&run)

	tasks := run_tasks(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, Node_Kind(tasks[0].kind), Node_Kind.Resize)
	testing.expect_value(t, state(&run, 0), flowgraph.Node_State.Done)   // (the run gives the Capture's picture itself)
	testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Running)
	testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Waiting)
	testing.expect(t, done_with_picture(&run, 1, 2, 2))

	tasks = run_tasks(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, Node_Kind(tasks[0].kind), Node_Kind.Save_File)
	testing.expect_value(t, input_shot(tasks[0]).size, [2]int{2, 2})
	// (the Capture's picture is read by none now: it is let go)
	testing.expect(t, run.flow.nodes[0].outputs[0].value.payload == nil)
	testing.expect(t, !flowgraph.run_over(&run.flow))
	testing.expect(t, done_with_text(&run, 2, PORT_FILE, "/tmp/a.png", .Save_File))
	testing.expect_value(t, len(run_tasks(&run)), 0)
	testing.expect(t, flowgraph.run_over(&run.flow))
}

@(test)
fan_out_gives_each_branch_the_same_picture :: proc(t: ^testing.T) {
	g := graph({.Capture, .Copy_Image, .Save_File, .Blur}, {{0, 1}, {0, 2}, {0, 3}})
	defer flowgraph.graph_free(&g)
	run: Run
	run_start(&run, g, picture(3, 3), {id = 1})
	defer run_free(&run)
	tasks := run_tasks(&run)
	testing.expect_value(t, len(tasks), 3)
	captured := run.flow.nodes[0].outputs[0].value
	for task in tasks {
		v, _ := flowgraph.task_input(task, 0)
		testing.expect(t, v.payload == captured.payload)
	}
	// (one reference: the Capture's output; the branches read it, none holds a copy)
	testing.expect_value(t, captured.payload.refs, 1)
}

@(test)
a_condition_sends_the_picture_one_way :: proc(t: ^testing.T) {
	g: flowgraph.Graph
	defer flowgraph.graph_free(&g)
	capture := flowgraph.node_add(&g, &CATALOG, int(Node_Kind.Capture), {})
	condition := flowgraph.node_add(&g, &CATALOG, int(Node_Kind.Condition), {})
	yes := flowgraph.node_add(&g, &CATALOG, int(Node_Kind.Copy_Image), {})
	no := flowgraph.node_add(&g, &CATALOG, int(Node_Kind.Save_File), {})
	after_no := flowgraph.node_add(&g, &CATALOG, int(Node_Kind.Notify), {})
	flowgraph.link(&g, &CATALOG, {capture, 0, condition, 0})
	flowgraph.link(&g, &CATALOG, {condition, 0, yes, 0})
	flowgraph.link(&g, &CATALOG, {condition, 1, no, 0})
	flowgraph.link(&g, &CATALOG, {no, 0, after_no, 0})
	n := flowgraph.graph_node(&g, condition)
	test, compare, value, source := flowgraph.param(&CATALOG, n, "test"), flowgraph.param(&CATALOG, n, "compare"), flowgraph.param(&CATALOG, n, "value"), flowgraph.param(&CATALOG, n, "source")
	test.number = f64(Condition_Test.Width)
	compare.number = f64(Condition_Compare.More)
	value.number = 100

	{
		run: Run
		run_start(&run, g, picture(200, 10), {id = 1})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{yes}))
		testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Done)
		testing.expect_value(t, state(&run, 3), flowgraph.Node_State.Skipped)
		testing.expect_value(t, state(&run, 4), flowgraph.Node_State.Skipped)
	}
	{
		run: Run
		run_start(&run, g, picture(50, 10), {id = 2})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{no}))
		testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Skipped)
	}
	{
		// (by its source: a screen is not a region)
		test.number = f64(Condition_Test.Source)
		source.number = f64(Source.Region)
		run: Run
		run_start(&run, g, picture(50, 10), {id = 3, source = .Screen})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{no}))
	}
}

@(test)
a_failure_skips_what_follows_it :: proc(t: ^testing.T) {
	g := graph({.Capture, .Resize, .Save_File, .Show_In_Folder, .Copy_Image}, {{0, 1}, {1, 2}, {2, 3}, {0, 4}})
	defer flowgraph.graph_free(&g)
	run: Run
	run_start(&run, g, picture(4, 4), {id = 1})
	defer run_free(&run)
	testing.expect_value(t, len(run_tasks(&run)), 2)   // (Resize and Copy image)
	testing.expect(t, flowgraph.run_finish(&run.flow, 1, {outcome = .Failed, message = "too small"}))
	testing.expect_value(t, len(run_tasks(&run)), 0)
	testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Failed)
	testing.expect_value(t, run.flow.nodes[1].message, "too small")
	testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Skipped)
	testing.expect_value(t, state(&run, 3), flowgraph.Node_State.Skipped)
	// (the other branch goes on)
	testing.expect_value(t, state(&run, 4), flowgraph.Node_State.Running)
	testing.expect(t, !flowgraph.run_over(&run.flow))
	testing.expect(t, flowgraph.run_finish(&run.flow, 4, {}))
	testing.expect(t, flowgraph.run_over(&run.flow))
	s := run_summary(&run)
	testing.expect(t, s.failed)
	testing.expect_value(t, s.title, "Screenshot copied to the clipboard")
	// (a late result is refused)
	testing.expect(t, !flowgraph.run_finish(&run.flow, 1, {}))
}

@(test)
annotate_waits_for_the_editor :: proc(t: ^testing.T) {
	g := graph({.Capture, .Annotate, .Save_File}, {{0, 1}, {1, 2}})
	defer flowgraph.graph_free(&g)
	{
		run: Run
		run_start(&run, g, picture(4, 4), {id = 1})
		defer run_free(&run)
		tasks := run_tasks(&run)
		testing.expect(t, slice.equal(ids(tasks), []u64{2}))
		testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Running)
		testing.expect(t, done_with_picture(&run, 1, 5, 5))
		tasks = run_tasks(&run)
		testing.expect(t, slice.equal(ids(tasks), []u64{3}))
		testing.expect_value(t, input_shot(tasks[0]).size, [2]int{5, 5})
	}
	{
		// the editor cancelled: the branch stops, nothing fails
		run: Run
		run_start(&run, g, picture(4, 4), {id = 2})
		defer run_free(&run)
		_ = run_tasks(&run)
		testing.expect(t, flowgraph.run_cancel(&run.flow, 1, "cancelled in the editor"))
		testing.expect_value(t, len(run_tasks(&run)), 0)
		testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Cancelled)
		testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Skipped)
		testing.expect(t, flowgraph.run_over(&run.flow))
		testing.expect(t, !run_summary(&run).failed)
	}
	{
		// a picture from the editor already, and a preview: Annotate passes it on
		for start in ([]Run_Start{{id = 3, annotated = true}, {id = 4, preview = true}}) {
			run: Run
			run_start(&run, g, picture(4, 4), start)
			tasks := run_tasks(&run)
			testing.expect_value(t, state(&run, 1), flowgraph.Node_State.Done)
			if start.preview {
				// (Save is an effect: off in a preview)
				testing.expect_value(t, len(tasks), 0)
				testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Skipped)
			} else {
				testing.expect(t, slice.equal(ids(tasks), []u64{3}))
			}
			run_free(&run)
		}
	}
}

// The editor's Done and Cancel as conditions between nodes: Save keeps the captured picture only when the person
// confirms, Notify says so only when they give up.
@(test)
the_editor_s_actions_decide_what_runs :: proc(t: ^testing.T) {
	g := graph({.Capture, .Annotate, .Save_File, .Notify}, {{0, 1}, {0, 2}, {0, 3}})
	defer flowgraph.graph_free(&g)
	when_port := u32(1)   // (the effects' action input, after their value input)
	DONE, CANCELLED :: u32(1), u32(2)   // (Annotate's action outputs, after its picture)
	_, linked := flowgraph.link(&g, &CATALOG, {2, DONE, 3, when_port})
	testing.expect(t, linked)
	_, linked = flowgraph.link(&g, &CATALOG, {2, CANCELLED, 4, when_port})
	testing.expect(t, linked)
	{
		run: Run
		run_start(&run, g, picture(4, 4), {id = 1})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{2}))   // (Save and Notify wait for the editor)
		testing.expect(t, done_with_picture(&run, 1, 5, 5))
		tasks := run_tasks(&run)
		testing.expect(t, slice.equal(ids(tasks), []u64{3}))
		testing.expect_value(t, input_shot(tasks[0]).size, [2]int{4, 4})   // (the captured picture, not the editor's)
		testing.expect_value(t, state(&run, 3), flowgraph.Node_State.Skipped)
	}
	{
		run: Run
		run_start(&run, g, picture(4, 4), {id = 2})
		defer run_free(&run)
		_ = run_tasks(&run)
		testing.expect(t, flowgraph.run_cancel(&run.flow, 1, "cancelled in the editor"))
		testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{4}))
		testing.expect_value(t, state(&run, 2), flowgraph.Node_State.Skipped)   // (on Cancel the save is skipped)
	}
}

@(test)
two_runs_go_on_side_by_side :: proc(t: ^testing.T) {
	g := graph({.Capture, .Annotate, .Copy_Image}, {{0, 1}, {1, 2}})
	defer flowgraph.graph_free(&g)
	a, b: Run
	run_start(&a, g, picture(4, 4), {id = 1})
	run_start(&b, g, picture(6, 6), {id = 2})
	defer { run_free(&a); run_free(&b) }
	_ = run_tasks(&a)
	_ = run_tasks(&b)
	// (the first waits on the editor while the second goes on)
	testing.expect(t, done_with_picture(&b, 1, 6, 6))
	testing.expect(t, slice.equal(ids(run_tasks(&b)), []u64{3}))
	testing.expect_value(t, state(&a, 1), flowgraph.Node_State.Running)
	testing.expect_value(t, state(&a, 2), flowgraph.Node_State.Waiting)
	testing.expect(t, flowgraph.run_cancel(&a.flow, 1, ""))
	_ = run_tasks(&a)   // (what followed the editor is decided: skipped)
	testing.expect(t, flowgraph.run_over(&a.flow))
	testing.expect_value(t, state(&a, 2), flowgraph.Node_State.Skipped)
	testing.expect(t, !flowgraph.run_over(&b.flow))
}

@(test)
a_run_copies_its_workflow :: proc(t: ^testing.T) {
	g := graph({.Capture, .Copy_Image}, {{0, 1}})
	defer flowgraph.graph_free(&g)
	run: Run
	run_start(&run, g, picture(2, 2), {id = 1})
	defer run_free(&run)
	// (the user changes the workflow while it runs: the run keeps what it started with)
	gone := [1]u64{2}
	flowgraph.nodes_delete(&g, &CATALOG, gone[:])
	testing.expect_value(t, len(run_tasks(&run)), 1)
}

@(test)
a_node_moves_only_as_its_table_says :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, s: flowgraph.Node_State, e: flowgraph.Node_Event, want: flowgraph.Node_State, ok: bool, loc := #caller_location) {
		next, done := flowgraph.node_step(s, e)
		testing.expect_value(t, done, ok, loc = loc)
		testing.expect_value(t, next, want, loc = loc)
	}
	check(t, .Waiting, .Start, .Running, true)
	check(t, .Running, .Finished, .Done, true)
	check(t, .Running, .Cancelled, .Cancelled, true)   // (the editor's Cancel)
	check(t, .Waiting, .Cancelled, .Waiting, false)    // (only a step under way is cancelled)
	check(t, .Done, .Failed, .Done, false)
	check(t, .Skipped, .Start, .Skipped, false)
}

@(test)
the_summary_says_what_the_run_did :: proc(t: ^testing.T) {
	g := graph({.Capture, .Read_Qr, .Copy_Text, .Notify}, {{0, 1}, {1, 2}, {2, 3}})
	defer flowgraph.graph_free(&g)
	run: Run
	run_start(&run, g, picture(2, 2), {id = 1})
	defer run_free(&run)
	_ = run_tasks(&run)
	testing.expect(t, done_with_text(&run, 1, PORT_TEXT, "https://example.org", .Read_Qr))
	tasks := run_tasks(&run)
	testing.expect(t, slice.equal(ids(tasks), []u64{3}))
	c: flowgraph.Result
	v, _ := flowgraph.task_input(tasks[0], 0)
	c.outputs[0] = flowgraph.value_hold(v)
	testing.expect(t, flowgraph.run_finish(&run.flow, 2, c))
	testing.expect(t, slice.equal(ids(run_tasks(&run)), []u64{4}))
	testing.expect(t, flowgraph.run_finish(&run.flow, 3, {}))
	testing.expect(t, flowgraph.run_over(&run.flow))
	s := run_summary(&run)
	testing.expect(t, s.notify)
	testing.expect_value(t, s.title, "QR code copied")
	testing.expect_value(t, s.body, "https://example.org")
}
