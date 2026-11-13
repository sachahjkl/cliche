package cliche

// The Workflows mode of the main window: a third mode beside the history and the settings (history_view.odin). Its
// toolbar button and Ctrl+Shift+W open it; the back bar and Escape go back.
//
//   left     the workflows (add, duplicate, rename, delete), each with the captures that run it
//   centre   the graph of the workflow chosen (ui.node_graph): the program owns the model (a flowgraph.Graph), the widget
//            draws it and says what the user did (Graph_Event); each change is one step of undo (a gt:undo stack)
//   right    the inspector of the node selected (workflow_inspector.odin), or the workflow's triggers
//
// The graph's nodes are made from the model when it changes (its version), not at each frame (ui.flow_nodes_make). Each
// node shows what the last run of its workflow did: its state, its message, a thumbnail of its picture (from the
// worker: Result_Node).

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import flowgraph "gt:flowgraph"
import lucide "gt:lucide"
import "gt:render"
import "gt:ui"
import undo "gt:undo"

// Steps of undo kept.
WORKFLOW_UNDO_MAX :: 100
// The wait after the last change of a parameter before the file is written (a slider dragged is one change).
WORKFLOW_SAVE_DELAY_MS :: 700
// Ems: the list's width, the inspector's.
WORKFLOW_LIST_EM :: 15
WORKFLOW_INSPECTOR_EM :: 19

// What the last run of the workflow shown did to a node.
Node_Last :: struct {
	state:   flowgraph.Node_State,
	message: string,           // owned
	tex:     render.Texture,   // its thumbnail (0: none)
	size:    [2]int,
}

Workflow_Mode :: struct {
	open:       bool,
	shown:      u64,                  // the workflow shown (its id; 0: none)
	view:       ui.Graph_View,
	selection:  [dynamic]u64,
	fit_due:    bool,

	// the graph as the widget takes it, made again when `made` changes
	flow:       ui.Flow_Nodes,
	made:       [3]u64,               // workflows.version, shown, last_version

	last:       map[u64]Node_Last,    // node id -> the last run's (of the workflow `last_of`)
	last_of:    u64,
	last_version: u64,

	history:    undo.Stack(flowgraph.Graph),   // the graph shown as it was before each change

	add:        ui.Command_Palette,   // the node kinds, searched
	add_at:     [2]f32,               // where the node added goes (graph units)
	add_from:   Maybe(ui.Graph_Port_Ref),   // the port a link was dropped from: the node added is linked to it
	node_menu:  ui.Key,
	menu_node:  u64,

	renaming:   u64,                  // the workflow whose name is being typed (0: none)
	rename:     ui.Text_Field,
	rename_focus: bool,               // its field takes the keyboard at its next build
	confirm_open: bool,
	delete_id:  u64,

	inspector:  ui.Node_Inspector,    // the node selected's parameters (workflow_inspector.odin)
	typing:     bool,                 // a field of the mode had the keyboard last frame: its keys are the field's
	save_key:   ui.Key,
	status:     string,               // owned
}

// Each port kind's colour, by flowgraph.Port_Kind (CATALOG.kinds): an action, a picture, a text, an address, a file,
// anything.
@(rodata)
PORT_KIND_COLORS := [6][3]f32{
	{0.86, 0.86, 0.90},
	{0.36, 0.56, 0.95},
	{0.30, 0.74, 0.46},
	{0.66, 0.45, 0.94},
	{0.95, 0.62, 0.25},
	{0.60, 0.62, 0.66},
}

// Each group's accent on its nodes (flowgraph.Node_Def.group).
GROUP_COLORS := [?]struct { group: string, color: [3]f32 }{
	{"Source",       {0.36, 0.56, 0.95}},
	{"Geometry",     {0.35, 0.68, 0.80}},
	{"Look",         {0.85, 0.45, 0.70}},
	{"Colour",       {0.92, 0.70, 0.25}},
	{"Filters",      {0.55, 0.60, 0.95}},
	{"Interactive",  {0.95, 0.50, 0.35}},
	{"Flow control", {0.70, 0.70, 0.72}},
	{"Outputs",      {0.30, 0.74, 0.46}},
}

// The mode's commands (the palette of the window, the sheet of keys).
Workflow_Action :: enum u8 { Back, Add_Node, Add_Workflow, Undo, Redo, Fit, Preview }

WORKFLOW_ACTIONS := [Workflow_Action]ui.Command{
	.Back         = {label = "Back to the history", group = "Workflows", keys = {{.Escape, {}}, {}}, icon = lucide.ARROW_LEFT, tags = {"close", "leave"}},
	.Add_Node     = {label = "Add a step…", group = "Workflows", keys = {{.A, {.Shift}}, {}}, icon = lucide.PLUS, tags = {"node", "new", "insert"}},
	.Add_Workflow = {label = "New workflow", group = "Workflows", icon = lucide.FILE_PLUS, tags = {"create", "graph"}},
	.Undo         = {label = "Undo", group = "Workflows", keys = {{.Z, {.Ctrl}}, {}}, icon = lucide.UNDO_2, tags = {"back", "revert"}},
	.Redo         = {label = "Redo", group = "Workflows", keys = {{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}}}, icon = lucide.REDO_2, tags = {"again"}},
	.Fit          = {label = "Show the whole workflow", group = "Workflows", keys = {{.F, {}}, {}}, icon = lucide.ZOOM_OUT, tags = {"fit", "zoom", "all"}},
	.Preview      = {label = "Run on the last capture", group = "Workflows", keys = {{.R, {.Ctrl}}, {}}, icon = lucide.PLAY, tags = {"preview", "test", "try"}},
}

////////////////////////////////
// Entering and leaving

workflow_mode_enter :: proc(app: ^App) {
	hw := &app.history_window
	m := &hw.workflow_mode
	if m.open { return }
	hw.settings_mode.open = false
	m.open = true
	if workflows_find(&app.workflows, m.shown) == nil { workflow_show(app, len(app.workflows.set.list) > 0 ? app.workflows.set.list[0].id : 0) }
	m.fit_due = true
	// (the uploaders' folder may have changed since: the Upload node's list is read again on the worker)
	worker_send(&app.worker, Job_Uploaders{})
}

workflow_mode_leave :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	if !m.open { return }
	m.open = false
	workflows_save(app)
}

// `cliche --workflows`: the main window, shown, in the Workflows mode.
workflows_show :: proc(app: ^App) {
	history_window_show(app)
	workflow_mode_enter(app)
}

// Another workflow shown: its selection, its undo and the last run's marks start again.
workflow_show :: proc(app: ^App, id: u64) {
	m := &app.history_window.workflow_mode
	if m.shown == id { return }
	m.shown = id
	clear(&m.selection)
	undo.reset(&m.history, flowgraph.graph_free)
	workflow_last_clear(app)
	m.last_of = id
	m.fit_due = true
	m.inspector.node = 0
	m.inspector.last_change = {}
}

// The list was read again (the file at the start): the first one shown.
workflow_view_reset :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	m.shown = 0
	if len(app.workflows.set.list) > 0 { workflow_show(app, app.workflows.set.list[0].id) }
}

workflow_mode_free :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	workflow_last_clear(app)
	delete(m.last)
	undo.destroy(&m.history, flowgraph.graph_free)
	delete(m.selection)
	ui.flow_nodes_destroy(&m.flow)
	ui.palette_destroy(&m.add)
	ui.field_destroy(&m.rename)
	ui.node_inspector_destroy(&m.inspector)
	delete(m.status)
	m^ = {}
}

// The thumbnails go with the renderer, and when the window hides (they are made again at the next run).
workflow_textures_drop :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	for _, &l in m.last {
		if l.tex != 0 { render.destroy_texture(&app.shared.r, l.tex) }
		l.tex, l.size = 0, {}
	}
	m.last_version += 1
}

@(private = "file")
workflow_last_clear :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	for _, &l in m.last {
		if l.tex != 0 { render.destroy_texture(&app.shared.r, l.tex) }
		delete(l.message)
	}
	clear(&m.last)
	m.last_version += 1
}

workflow_view_status :: proc(app: ^App, text: string) {
	m := &app.history_window.workflow_mode
	delete(m.status)
	m.status = strings.clone(text)
}

////////////////////////////////
// What the runs tell the mode

// Whether the mode shows `run`: its nodes' thumbnails are made then.
workflow_view_wants :: proc(app: ^App, run: ^Run) -> bool {
	hw := &app.history_window
	return hw.visible && hw.workflow_mode.open && hw.workflow_mode.shown == run.workflow
}

workflow_view_run_started :: proc(app: ^App, run: ^Run) {
	m := &app.history_window.workflow_mode
	if m.shown != run.workflow { return }
	for _, &l in m.last {
		delete(l.message)
		l.message = ""
		l.state = .Waiting
	}
	workflow_view_follow(app, run)
}

// The run's states copied into the marks of the nodes shown.
workflow_view_follow :: proc(app: ^App, run: ^Run) {
	m := &app.history_window.workflow_mode
	if m.shown != run.workflow { return }
	for rn, i in run.flow.nodes {
		id := run.flow.graph.nodes[i].id
		l := m.last[id]
		l.state = rn.state
		if l.message != rn.message {
			delete(l.message)
			l.message = strings.clone(rn.message)
		}
		m.last[id] = l
	}
	m.last_version += 1
	app.history_window.host.settle = max(app.history_window.host.settle, 2)
}

workflow_view_run_ended :: proc(app: ^App, run: ^Run) {
	workflow_view_follow(app, run)
	if run.preview { workflow_view_status(app, "The preview ran on the newest capture of the history: nothing was copied, saved or sent.") }
}

// A node's thumbnail from the worker (`rgba` is not kept: the texture holds a copy).
workflow_view_thumbnail :: proc(app: ^App, run: ^Run, node: int, rgba: []u8, size: [2]int) {
	hw := &app.history_window
	m := &hw.workflow_mode
	if rgba == nil || !hw.opened || m.shown != run.workflow || node >= len(run.flow.graph.nodes) { return }
	id := run.flow.graph.nodes[node].id
	l := m.last[id]
	r := &app.shared.r
	if l.tex != 0 && l.size != size {
		render.destroy_texture(r, l.tex)
		l.tex = 0
	}
	if l.tex == 0 { l.tex = render.create_texture_rgba(r, size.x, size.y) }
	if l.tex != 0 { render.update_texture_rgba(r, l.tex, 0, 0, size.x, size.y, rgba) }
	l.size = size
	m.last[id] = l
	m.last_version += 1
}

////////////////////////////////
// The mode

// The keys of the mode (no dialog open).
workflow_keys :: proc(app: ^App) {
	m := &app.history_window.workflow_mode
	if m.typing { return }
	for a in Workflow_Action {
		// (F is the graph's own; Escape is the graph's while a gesture runs or nodes are selected, then it leaves)
		if a == .Fit { continue }
		if a == .Back && (m.view.gesture != nil || len(m.selection) > 0) { continue }
		if ui.command_pressed(WORKFLOW_ACTIONS[a]) { workflow_action(app, a); return }
	}
}

workflow_action :: proc(app: ^App, a: Workflow_Action) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	switch a {
	case .Back:         workflow_mode_leave(app)
	case .Add_Node:     workflow_add_open(app, workflow_view_center(m), nil)
	case .Add_Workflow: workflow_new(app)
	case .Undo:         workflow_undo(app, back = true)
	case .Redo:         workflow_undo(app, back = false)
	case .Fit:          m.fit_due = true
	case .Preview:
		if wf == nil { return }
		if !workflow_preview(app, wf) { workflow_view_status(app, "The history holds no picture to run the workflow on.") } else { workflow_view_status(app, "Running on the newest capture…") }
	}
}

// The mode of the main window: the back bar, then the list, the graph and the inspector.
workflow_build :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	m.typing = false
	if m.save_key == 0 { m.save_key = ui.key_from_string(0, "workflow_save") }
	if app.workflows_save_due && ui.timer_due(m.save_key) {
		workflows_save(app)
		m.inspector.last_change = {}   // (the next change of the same parameter is a step of its own)
	}
	workflow_bar(app, em)
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###workflow_body") {
		workflow_list(app, em)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###workflow_graph_col") { workflow_graph(app, em) }
		workflow_inspector(app, em)
	}
	workflow_footer(app, em)
	workflow_dialogs(app, em)
}

@(private = "file")
workflow_bar :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.6)), axis = .X, cross = .Center})
	if ui.row(id = "###workflow_bar") {
		ui.spacer(ui.px(em * 0.5))
		if workflow_icon_button("back", lucide.ARROW_LEFT, "Back to the history (Escape)", em) { workflow_mode_leave(app) }
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.05), text_pad = 0})
		ui.label("Workflows###workflow_title")
		if workflow_icon_button("add_node", lucide.PLUS, "Add a step (Shift+A, a right click on the graph)", em) { workflow_action(app, .Add_Node) }
		if workflow_icon_button("undo", lucide.UNDO_2, "Undo (Ctrl+Z)", em, undo.can_undo(&m.history)) { workflow_action(app, .Undo) }
		if workflow_icon_button("redo", lucide.REDO_2, "Redo (Ctrl+Shift+Z)", em, undo.can_redo(&m.history)) { workflow_action(app, .Redo) }
		if workflow_icon_button("fit", lucide.ZOOM_OUT, "Show the whole workflow (F)", em) { workflow_action(app, .Fit) }
		ui.spacer(ui.px(em * 0.5))
		ui.next({height = ui.px(math.round(em * 2))})
		if ui.button_icon("###preview", lucide.PLAY, "Run on the last capture", disabled = m.shown == 0).clicked { workflow_action(app, .Preview) }
		ui.spacer(ui.px(em * 0.6))
	}
}

@(private = "file")
workflow_footer :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	ui.hline(ui.fill())
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	if ui.row(id = "###workflow_footer") {
		ui.spacer(ui.px(em * 0.8))
		text := m.status
		if app.workflows_problem != "" { text = app.workflows_problem }
		tag := app.workflows_problem != "" ? "bad" : "weak"
		if ui.tags(tag) {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###workflow_status", ui.text_shown(text)))
		}
	}
}

// The graph of the workflow shown, or what stands for it.
@(private = "file")
workflow_graph :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil {
		switch ui.empty_state("no_workflow", {icon = lucide.GIT_FORK, title = "No workflow", note = "A workflow says what happens after a capture: the steps the picture goes through, and where it goes.", actions = {{text = "New workflow", icon = lucide.PLUS, intent = .Primary}, {text = "The default workflows", icon = lucide.ROTATE_CCW}}}) {
		case 0: workflow_new(app)
		case 1: workflow_defaults_back(app)
		}
		return
	}
	workflow_graph_make(app, wf, em)
	if m.fit_due && m.view.size.x > 0 {
		ui.graph_fit(&m.view, m.flow.nodes[:])
		m.fit_due = false
	}
	opts := ui.Graph_Options{
		user = app,
		kind_colors = workflow_kind_colors(),
		can_link = proc(user: rawptr, l: ui.Graph_Link) -> bool {
			app := (^App)(user)
			wf := workflows_find(&app.workflows, app.history_window.workflow_mode.shown)
			return wf != nil && flowgraph.can_link(&wf.graph, &CATALOG, ui.flow_link(l))
		},
		icon_font = app.history_window.icons,
		snap = 10,
		minimap = len(wf.graph.nodes) > 6,
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	events := ui.node_graph("###workflow_graph", &m.view, m.flow.nodes[:], m.flow.links[:], m.selection[:], opts)
	// (the first build lays the area out: it is fitted at the next one, once it has its size)
	if m.fit_due { app.history_window.host.settle = max(app.history_window.host.settle, 2) }
	for e in events { workflow_graph_event(app, wf, e) }
	if len(wf.graph.nodes) == 1 && len(events) == 0 {
		// (a workflow with its Capture alone: what to do next, under the graph)
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), text_pad = em * 0.6})
			ui.label("Right click the graph, or drag from the Capture's picture, to add a step.###workflow_hint")
		}
	}
}

// The nodes and links the widget takes, made again when the workflow or the last run's marks change.
@(private = "file")
workflow_graph_make :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, em: f32) {
	m := &app.history_window.workflow_mode
	stamp := [3]u64{app.workflows.version, m.shown, m.last_version}
	if stamp == m.made && len(m.flow.nodes) == len(wf.graph.nodes) { return }
	m.made = stamp
	ui.flow_nodes_make(&m.flow, &wf.graph, &CATALOG, {user = app, look = workflow_node_look})
}

// What a node shows beyond its kind: what it does with its parameters (a Capture: the captures that run its workflow),
// its group's accent, and what the last run did.
@(private = "file")
workflow_node_look :: proc(user: rawptr, n: ^flowgraph.Node, def: ^flowgraph.Node_Def) -> ui.Flow_Node_Look {
	app := (^App)(user)
	m := &app.history_window.workflow_mode
	subtitle: string
	if Node_Kind(n.kind) == .Capture {
		if wf := workflows_find(&app.workflows, m.shown); wf != nil { subtitle = workflow_triggers_text(wf) }
	} else {
		subtitle = node_summary(n)
	}
	c := group_color(def.group)
	l := m.last[n.id]
	return {
		subtitle = subtitle, color = draw.srgb(c.x, c.y, c.z), state = ui.flow_state(l.state), message = l.message,
		thumbnail = l.tex, thumbnail_size = l.size,
	}
}

@(private = "file")
group_color :: proc(group: string) -> [3]f32 {
	for g in GROUP_COLORS { if g.group == group { return g.color } }
	return {0.60, 0.62, 0.66}
}

// What a Capture node says under its title: the captures that run its workflow.
workflow_triggers_text :: proc(wf: ^flowgraph.Graph_Entry) -> string {
	triggers := workflow_triggers(wf)
	if triggers == {} { return "no capture runs it" }
	b := strings.builder_make(context.temp_allocator)
	for t in triggers {
		if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, TRIGGER_NAMES[t])
	}
	return strings.to_string(b)
}

@(private = "file")
workflow_kind_colors :: proc() -> []draw.Color {
	out := make([]draw.Color, len(PORT_KIND_COLORS), context.temp_allocator)
	for c, k in PORT_KIND_COLORS { out[k] = draw.srgb(c.x, c.y, c.z) }
	return out
}

// What the user did on the graph, applied to the model: each change one step of undo, and the file written.
@(private = "file")
workflow_graph_event :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, e: ui.Graph_Event) {
	m := &app.history_window.workflow_mode
	g := &wf.graph
	switch v in e {
	case ui.Graph_Moved:
		workflow_undo_push(app, wf)
		flowgraph.nodes_move(g, v.nodes, v.delta)
		workflows_changed(app, now = true)
	case ui.Graph_Linked:
		l := ui.flow_link(v.link)
		if !flowgraph.can_link(g, &CATALOG, l) { return }
		workflow_undo_push(app, wf)
		_, _ = flowgraph.link(g, &CATALOG, l)
		workflows_changed(app, now = true)
	case ui.Graph_Unlinked:
		workflow_undo_push(app, wf)
		flowgraph.unlink(g, ui.flow_link(v.link))
		workflows_changed(app, now = true)
	case ui.Graph_Selected:
		clear(&m.selection)
		append(&m.selection, ..v.nodes)
	case ui.Graph_Deleted:
		workflow_undo_push(app, wf)
		for l in v.links { flowgraph.unlink(g, ui.flow_link(l)) }
		if flowgraph.nodes_delete(g, &CATALOG, v.nodes) > 0 { clear(&m.selection) }
		workflows_changed(app, now = true)
	case ui.Graph_Context:
		if v.node == 0 {
			workflow_add_open(app, v.at, nil)
		} else {
			m.menu_node = v.node
			if m.node_menu == 0 { m.node_menu = ui.key_from_string(0, "workflow_node_menu") }
			ui.ctx_menu_open(m.node_menu, ui.mouse_pos(), search = false)
		}
	case ui.Graph_Opened:
		clear(&m.selection)
		append(&m.selection, v.node)
	case ui.Graph_Dropped_Link:
		workflow_add_open(app, v.at, v.from)
	}
}

// The centre of the graph's area, in graph units (where Shift+A adds).
@(private = "file")
workflow_view_center :: proc(m: ^Workflow_Mode) -> [2]f32 {
	s := m.view.scale > 0 ? m.view.scale : 1
	return ui.graph_from_screen(&m.view, m.view.origin + m.view.size / 2) - {80, 30} * (1 / s)
}

////////////////////////////////
// Adding a node

// The searchable list of node kinds, for a node at `at`, linked to `from` when a link was dropped there.
@(private = "file")
workflow_add_open :: proc(app: ^App, at: [2]f32, from: Maybe(ui.Graph_Port_Ref)) {
	m := &app.history_window.workflow_mode
	if workflows_find(&app.workflows, m.shown) == nil { return }
	m.add_at, m.add_from = at, from
	ui.palette_open(&m.add)
}

// A node of `kind` added where the palette was opened, linked to the port a link was dropped from (by its first port
// that fits).
@(private = "file")
workflow_add_chosen :: proc(app: ^App, kind: int) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil { return }
	workflow_undo_push(app, wf)
	at := m.add_at
	id: u64
	if from, has := m.add_from.?; has {
		if from.side == .In { at.x -= 220 }   // (a node that feeds a port goes before it)
		id = flowgraph.node_add_linked(&wf.graph, &CATALOG, kind, at, from.node, from.port, from.side == .Out)
	} else {
		id = flowgraph.node_add(&wf.graph, &CATALOG, kind, at)
	}
	if id == 0 {
		undo.drop_last(&m.history, flowgraph.graph_free)
		return
	}
	clear(&m.selection)
	append(&m.selection, id)
	workflows_changed(app, now = true)
}

////////////////////////////////
// Undo

// The graph shown as it is, kept before a change.
workflow_undo_push :: proc(app: ^App, wf: ^flowgraph.Graph_Entry) {
	m := &app.history_window.workflow_mode
	undo.push(&m.history, flowgraph.graph_clone(wf.graph), WORKFLOW_UNDO_MAX, flowgraph.graph_free)
}

// The graph shown back as it was before the last change (`back`), or again as the last undo found it. Its name and its
// triggers are not the graph's: they stay as they are now.
@(private = "file")
workflow_undo :: proc(app: ^App, back: bool) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil { return }
	g: flowgraph.Graph
	ok: bool
	if back { g, ok = undo.undo(&m.history, wf.graph) } else { g, ok = undo.redo(&m.history, wf.graph) }
	if !ok { return }
	wf.graph = g   // (the graph it replaces is the stack's now)
	clear(&m.selection)
	m.inspector.node = 0
	workflows_changed(app, now = true)
}

////////////////////////////////
// Dialogs

@(private = "file")
workflow_dialogs :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	if m.add.open {
		if wf := workflows_find(&app.workflows, m.shown); wf != nil {
			commands, enabled := ui.flow_palette(&wf.graph, &CATALOG, m.add_from)
			if i, _ := ui.palette(&m.add, commands, enabled); i >= 0 { workflow_add_chosen(app, i) }
		} else {
			m.add.open = false
		}
	}
	if m.node_menu != 0 { if ui.ctx_menu(m.node_menu) {
		wf := workflows_find(&app.workflows, m.shown)
		n := wf != nil ? flowgraph.graph_node(&wf.graph, m.menu_node) : nil
		if n != nil {
			g := &wf.graph
			// (a copy appended moves the nodes: what the items below read of this one is taken first)
			id, kind := n.id, n.kind
			def := &CATALOG.nodes[kind]
			can_delete := flowgraph.graph_count(g, kind) > def.min_count
			if ui.menu_item("Duplicate", icon = lucide.COPY, icon_font = app.history_window.icons, enabled = flowgraph.can_add(g, &CATALOG, kind)).clicked {
				workflow_undo_push(app, wf)
				if copied := flowgraph.node_copy(g, &CATALOG, id, {30, 30}); copied != 0 {
					clear(&m.selection)
					append(&m.selection, copied)
					workflows_changed(app, now = true)
				} else {
					undo.drop_last(&m.history, flowgraph.graph_free)
				}
			}
			if ui.menu_item("Reset its settings", icon = lucide.REFRESH_CW, icon_font = app.history_window.icons, enabled = len(def.params) > 0).clicked {
				workflow_undo_push(app, wf)
				if reset := flowgraph.graph_node(g, id); reset != nil { flowgraph.node_params_default(&CATALOG, reset) }
				m.inspector.node = 0
				workflows_changed(app, now = true)
			}
			ui.menu_separator()
			if ui.menu_item("Delete", "Delete", icon = lucide.TRASH_2, icon_font = app.history_window.icons, enabled = can_delete).clicked {
				workflow_undo_push(app, wf)
				ids := [1]u64{id}
				flowgraph.nodes_delete(g, &CATALOG, ids[:])
				clear(&m.selection)
				workflows_changed(app, now = true)
			}
		}
	} }
	if m.confirm_open {
		wf := workflows_find(&app.workflows, m.delete_id)
		title := wf != nil ? fmt.tprintf("Delete the workflow %q?", wf.name) : "Delete the workflow?"
		note := "Its steps go with it. Undo cannot bring it back."
		if wf != nil && len(wf.labels) > 0 { note = "Its steps go with it, and the captures it runs will run nothing until another workflow takes them." }
		switch ui.confirm("workflow_delete", &m.confirm_open, {title = title, note = note, act = "Delete"}) {
		case .Confirmed:
			workflows_remove(&app.workflows, m.delete_id)
			if m.shown == m.delete_id { workflow_show(app, len(app.workflows.set.list) > 0 ? app.workflows.set.list[0].id : 0) }
			workflows_changed(app, now = true)
		case .Cancelled, .None:
		}
	}
}

// A new workflow with its Capture node, shown, its name being typed.
workflow_new :: proc(app: ^App) {
	wf := flowgraph.Graph_Entry{name = strings.clone("New workflow")}
	flowgraph.node_add(&wf.graph, &CATALOG, int(Node_Kind.Capture), {0, 0})
	id := workflows_add(&app.workflows, wf)
	workflow_show(app, id)
	workflow_rename_start(app, id)
	workflows_changed(app, now = true)
}

// The default workflows added back (after every workflow was deleted).
@(private = "file")
workflow_defaults_back :: proc(app: ^App) {
	defaults := workflows_default()
	for &wf in defaults.set.list {
		triggers := workflow_triggers(&wf)
		id := workflows_add(&app.workflows, wf)
		for t in triggers { if workflows_for(&app.workflows, t) == nil { workflows_bind(&app.workflows, id, t, true) } }
	}
	delete(defaults.set.list)   // (the workflows are the app's now)
	if len(app.workflows.set.list) > 0 { workflow_show(app, app.workflows.set.list[0].id) }
	workflows_changed(app, now = true)
}

workflow_rename_start :: proc(app: ^App, id: u64) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, id)
	if wf == nil { return }
	m.renaming, m.rename_focus = id, true
	ui.field_set(&m.rename, wf.name)
	ui.field_select_all(&m.rename)
}

@(private = "file")
workflow_icon_button :: proc(id, glyph, tip: string, em: f32, enabled := true) -> bool {
	ui.next({width = ui.px(math.round(em * 2.1)), height = ui.px(math.round(em * 2.1)), font_size = em * 1.15})
	return ui.icon_button(fmt.tprintf("wf_%s", id), glyph, tip = tip, disabled = !enabled).clicked && enabled
}
