package cliche

import "core:slice"
import "core:testing"

// A picture of `w` × `h` pixels, grey (owned).
@(private = "file")
picture :: proc(w, h: int) -> Shot {
	rgba := make([]u8, w * h * 4)
	for &b in rgba { b = 128 }
	return {rgba = rgba, size = {w, h}, source = .Region, scale = 1}
}

// A workflow of `kinds` (Capture first), linked port 0 to port 0 by `links` (places in `kinds`). The node ids are the
// places plus one.
@(private = "file")
graph :: proc(kinds: []Node_Kind, links: [][2]int) -> (wf: Workflow) {
	for k, i in kinds { workflow_node_add(&wf, k, {f32(i) * 200, 0}) }
	for l in links { workflow_link(&wf, {u64(l[0] + 1), 0, u64(l[1] + 1), 0}) }
	return
}

@(private = "file")
ids :: proc(tasks: []Run_Task) -> []u64 {
	out := make([]u64, len(tasks), context.temp_allocator)
	for t, i in tasks { out[i] = t.id }
	return out
}

// A node's work done, with a new picture (a transform's) on its output.
@(private = "file")
done_with_picture :: proc(run: ^Run, node: int, w, h: int) -> bool {
	r := Run_Result{ok = true, made = {0}}
	r.outputs[0] = {kind = .Image, picture = picture_make(picture(w, h))}
	return run_finish(run, node, r)
}

@(test)
nodes_run_in_the_order_of_their_links :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Resize, .Save_File}, {{0, 1}, {1, 2}})
	defer workflow_free(&wf)
	run: Run
	run_start(&run, wf, picture(4, 4), {id = 1})
	defer run_free(&run)

	tasks := run_next(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, tasks[0].kind, Node_Kind.Resize)
	testing.expect_value(t, run.nodes[1].state, Node_State.Running)
	testing.expect_value(t, run.nodes[2].state, Node_State.Idle)
	testing.expect(t, done_with_picture(&run, 1, 2, 2))

	tasks = run_next(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, tasks[0].kind, Node_Kind.Save_File)
	testing.expect_value(t, tasks[0].inputs[0].picture.shot.size, [2]int{2, 2})
	// (the Capture's picture is read by none now: it is let go)
	testing.expect(t, run.nodes[0].outputs[0].picture == nil)
	testing.expect(t, !run_over(&run))
	r := Run_Result{ok = true, made = {0}}
	r.outputs[0] = {kind = .File, text = clone_text("/tmp/a.png")}
	testing.expect(t, run_finish(&run, 2, r))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect(t, run_over(&run))
}

@(test)
fan_out_gives_each_branch_the_same_picture :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Copy_Image, .Save_File, .Blur}, {{0, 1}, {0, 2}, {0, 3}})
	defer workflow_free(&wf)
	run: Run
	run_start(&run, wf, picture(3, 3), {id = 1})
	defer run_free(&run)
	tasks := run_next(&run)
	testing.expect_value(t, len(tasks), 3)
	for task in tasks { testing.expect(t, task.inputs[0].picture == run.nodes[0].outputs[0].picture) }
	// (one reference: the Capture's output; the branches read it, none holds a copy)
	testing.expect_value(t, run.nodes[0].outputs[0].picture.refs, 1)
}

@(test)
a_condition_sends_the_picture_one_way :: proc(t: ^testing.T) {
	wf: Workflow
	defer workflow_free(&wf)
	capture := workflow_node_add(&wf, .Capture, {})
	condition := workflow_node_add(&wf, .Condition, {})
	yes := workflow_node_add(&wf, .Copy_Image, {})
	no := workflow_node_add(&wf, .Save_File, {})
	after_no := workflow_node_add(&wf, .Notify, {})
	workflow_link(&wf, {capture, 0, condition, 0})
	workflow_link(&wf, {condition, 0, yes, 0})
	workflow_link(&wf, {condition, 1, no, 0})
	workflow_link(&wf, {no, 0, after_no, 0})
	n := workflow_node(&wf, condition)
	test, compare, value, source := node_param(n, "test"), node_param(n, "compare"), node_param(n, "value"), node_param(n, "source")
	test.number = f64(Condition_Test.Width)
	compare.number = f64(Condition_Compare.More)
	value.number = 100

	{
		run: Run
		run_start(&run, wf, picture(200, 10), {id = 1})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_next(&run)), []u64{yes}))
		testing.expect_value(t, run.nodes[1].state, Node_State.Done)
		testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
		testing.expect_value(t, run.nodes[4].state, Node_State.Skipped)
	}
	{
		run: Run
		run_start(&run, wf, picture(50, 10), {id = 2})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_next(&run)), []u64{no}))
		testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	}
	{
		// (by its source: a screen is not a region)
		test.number = f64(Condition_Test.Source)
		source.number = f64(Source.Region)
		run: Run
		run_start(&run, wf, picture(50, 10), {id = 3, source = .Screen})
		defer run_free(&run)
		testing.expect(t, slice.equal(ids(run_next(&run)), []u64{no}))
	}
}

@(test)
a_failure_skips_what_follows_it :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Resize, .Save_File, .Show_In_Folder, .Copy_Image}, {{0, 1}, {1, 2}, {2, 3}, {0, 4}})
	defer workflow_free(&wf)
	run: Run
	run_start(&run, wf, picture(4, 4), {id = 1})
	defer run_free(&run)
	testing.expect_value(t, len(run_next(&run)), 2)   // (Resize and Copy image)
	testing.expect(t, run_finish(&run, 1, {message = "too small"}))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect_value(t, run.nodes[1].state, Node_State.Failed)
	testing.expect_value(t, run.nodes[1].message, "too small")
	testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
	// (the other branch goes on)
	testing.expect_value(t, run.nodes[4].state, Node_State.Running)
	testing.expect(t, !run_over(&run))
	r := Run_Result{ok = true}
	testing.expect(t, run_finish(&run, 4, r))
	testing.expect(t, run_over(&run))
	s := run_summary(&run)
	testing.expect(t, s.failed)
	testing.expect_value(t, s.title, "Screenshot copied to the clipboard")
	// (a late result is refused)
	testing.expect(t, !run_finish(&run, 1, {ok = true}))
}

@(test)
annotate_waits_for_the_editor :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Annotate, .Save_File}, {{0, 1}, {1, 2}})
	defer workflow_free(&wf)
	{
		run: Run
		run_start(&run, wf, picture(4, 4), {id = 1})
		defer run_free(&run)
		tasks := run_next(&run)
		testing.expect(t, slice.equal(ids(tasks), []u64{2}))
		testing.expect_value(t, run.nodes[1].state, Node_State.Waiting)
		testing.expect(t, done_with_picture(&run, 1, 5, 5))
		tasks = run_next(&run)
		testing.expect(t, slice.equal(ids(tasks), []u64{3}))
		testing.expect_value(t, tasks[0].inputs[0].picture.shot.size, [2]int{5, 5})
	}
	{
		// the editor closed without Done: the branch stops, nothing fails
		run: Run
		run_start(&run, wf, picture(4, 4), {id = 2})
		defer run_free(&run)
		_ = run_next(&run)
		testing.expect(t, run_cancel(&run, 1, "closed without Done"))
		testing.expect_value(t, len(run_next(&run)), 0)
		testing.expect_value(t, run.nodes[1].state, Node_State.Skipped)
		testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
		testing.expect(t, run_over(&run))
		testing.expect(t, !run_summary(&run).failed)
	}
	{
		// a picture from the editor already, and a preview: Annotate passes it on
		for start in ([]Run_Start{{id = 3, annotated = true}, {id = 4, preview = true}}) {
			run: Run
			run_start(&run, wf, picture(4, 4), start)
			tasks := run_next(&run)
			testing.expect_value(t, run.nodes[1].state, Node_State.Done)
			if start.preview {
				// (Save is an effect: off in a preview)
				testing.expect_value(t, len(tasks), 0)
				testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
			} else {
				testing.expect(t, slice.equal(ids(tasks), []u64{3}))
			}
			run_free(&run)
		}
	}
}

@(test)
two_runs_go_on_side_by_side :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Annotate, .Copy_Image}, {{0, 1}, {1, 2}})
	defer workflow_free(&wf)
	a, b: Run
	run_start(&a, wf, picture(4, 4), {id = 1})
	run_start(&b, wf, picture(6, 6), {id = 2})
	defer { run_free(&a); run_free(&b) }
	_ = run_next(&a)
	_ = run_next(&b)
	// (the first waits on the editor while the second goes on)
	testing.expect(t, done_with_picture(&b, 1, 6, 6))
	testing.expect(t, slice.equal(ids(run_next(&b)), []u64{3}))
	testing.expect_value(t, a.nodes[1].state, Node_State.Waiting)
	testing.expect_value(t, a.nodes[2].state, Node_State.Idle)
	testing.expect(t, run_cancel(&a, 1, ""))
	_ = run_next(&a)   // (what followed the editor is decided: skipped)
	testing.expect(t, run_over(&a))
	testing.expect_value(t, a.nodes[2].state, Node_State.Skipped)
	testing.expect(t, !run_over(&b))
}

@(test)
a_run_copies_its_workflow :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Copy_Image}, {{0, 1}})
	defer workflow_free(&wf)
	run: Run
	run_start(&run, wf, picture(2, 2), {id = 1})
	defer run_free(&run)
	// (the user changes the workflow while it runs: the run keeps what it started with)
	gone := [1]u64{2}
	workflow_nodes_delete(&wf, gone[:])
	testing.expect_value(t, len(run_next(&run)), 1)
}

@(test)
a_node_moves_only_as_its_table_says :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, s: Node_State, e: Node_Event, want: Node_State, ok: bool, loc := #caller_location) {
		next, done := node_step(s, e)
		testing.expect_value(t, done, ok, loc = loc)
		testing.expect_value(t, next, want, loc = loc)
	}
	check(t, .Idle, .Start, .Running, true)
	check(t, .Idle, .Wait, .Waiting, true)
	check(t, .Running, .Finished, .Done, true)
	check(t, .Waiting, .Cancelled, .Skipped, true)
	check(t, .Running, .Cancelled, .Running, false)   // (only a person cancels: the editor)
	check(t, .Done, .Failed, .Done, false)
	check(t, .Skipped, .Start, .Skipped, false)
}

@(test)
the_summary_says_what_the_run_did :: proc(t: ^testing.T) {
	wf := graph({.Capture, .Read_Qr, .Copy_Text, .Notify}, {{0, 1}, {1, 2}, {2, 3}})
	defer workflow_free(&wf)
	run: Run
	run_start(&run, wf, picture(2, 2), {id = 1})
	defer run_free(&run)
	_ = run_next(&run)
	r := Run_Result{ok = true, made = {0}}
	r.outputs[0] = {kind = .Text, text = clone_text("https://example.org"), origin = .Read_Qr}
	testing.expect(t, run_finish(&run, 1, r))
	tasks := run_next(&run)
	testing.expect(t, slice.equal(ids(tasks), []u64{3}))
	c := Run_Result{ok = true, made = {0}}
	c.outputs[0] = value_clone(tasks[0].inputs[0])
	testing.expect(t, run_finish(&run, 2, c))
	testing.expect(t, slice.equal(ids(run_next(&run)), []u64{4}))
	testing.expect(t, run_finish(&run, 3, {ok = true}))
	testing.expect(t, run_over(&run))
	s := run_summary(&run)
	testing.expect(t, s.notify)
	testing.expect_value(t, s.title, "QR code copied")
	testing.expect_value(t, s.body, "https://example.org")
}

@(private = "file")
clone_text :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}
