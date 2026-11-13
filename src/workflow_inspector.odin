package cliche

// The sides of the Workflows mode (workflow_view.odin): the list of workflows on the left, the inspector on the right.
// The inspector draws a node's parameters from its kind's schema (ui.node_inspector: a number and its slider, a toggle,
// a colour and its picker, a segmented choice or a list, a text field, a folder and the system's dialog, the
// uploaders), then applies what changed after its step of undo. With no node selected, it shows the workflow: its name
// and the captures that run it.

import "core:fmt"
import "core:math"
import "core:strings"
import flowgraph "gt:flowgraph"
import lucide "gt:lucide"
import "gt:ui"

// The folder chosen in the system's dialog for a Save node (app_pick_folder).
workflow_folder_chosen :: proc(app: ^App, workflow, node: u64, path: string) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, workflow)
	if wf == nil || path == "" { return }
	n := flowgraph.graph_node(&wf.graph, node)
	if n == nil { return }
	_, i := flowgraph.param_def(&CATALOG, n, "folder")
	if i < 0 { return }
	// (the undo steps are the graph shown's: another workflow's change is not one of them)
	if workflow == m.shown { workflow_undo_push(app, wf) }
	value := n.params[i]
	value.text = path
	flowgraph.param_set(n, i, value)
	m.inspector.node = 0   // (its field shows the new folder)
	workflows_changed(app, now = true)
}

////////////////////////////////
// The list

workflow_list :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(math.round(em * WORKFLOW_LIST_EM)), height = ui.fill(), axis = .Y})
	if ui.column(id = "###wf_list") { workflow_list_body(app, em) }
}

@(private = "file")
workflow_list_body :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.4)), axis = .X, cross = .Center})
	if ui.row(id = "###wf_list_head") {
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 0.78), text_pad = 0})
			ui.label("WORKFLOWS###wf_list_title")
		}
		if list_icon_button("new", lucide.PLUS, "New workflow", em, true) { workflow_new(app) }
		if list_icon_button("rename", lucide.PENCIL, "Rename (or double-click its name)", em, m.shown != 0) { workflow_rename_start(app, m.shown) }
		if list_icon_button("duplicate", lucide.COPY, "Duplicate", em, m.shown != 0) { workflow_duplicate(app, m.shown) }
		if list_icon_button("delete", lucide.TRASH_2, "Delete…", em, m.shown != 0) {
			m.delete_id = m.shown
			m.confirm_open = true
		}
		ui.spacer(ui.px(em * 0.4))
	}
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.scroll_y("###wf_list_scroll") {
		for &wf in app.workflows.set.list { workflow_list_item(app, &wf, em) }
		unbound := workflows_unbound(&app.workflows)
		if unbound != {} {
			ui.spacer(ui.px(em * 0.6))
			b := strings.builder_make(context.temp_allocator)
			for t in Trigger {
				if t not_in unbound { continue }
				if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
				strings.write_string(&b, TRIGGER_NAMES[t])
			}
			if ui.tags("weak") {
				ui.next({width = ui.fill(), font_size = math.round(em * 0.84), text_pad = em * 0.8})
				ui.paragraph(fmt.tprintf("No workflow runs for: %s. Choose one in a workflow's triggers.###wf_unbound", strings.to_string(b)))
			}
		}
	}
}

@(private = "file")
workflow_list_item :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###wf_item_%d", wf.id)) { workflow_list_item_body(app, wf, em) }
}

@(private = "file")
workflow_list_item_body :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, em: f32) {
	m := &app.history_window.workflow_mode
	shown := wf.id == m.shown
	if m.renaming == wf.id {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 2))})
		r := ui.line_edit("###wf_rename", &m.rename)
		m.typing |= r.focused
		if m.rename_focus && r.box != nil {
			ui.set_focus(r.box.key)
			m.rename_focus = false
		}
		switch {
		case r.committed || (!r.focused && !m.rename_focus && r.box != nil && ui.focus_key() != r.box.key):
			// (Enter, or the keyboard gone elsewhere: the name typed is kept)
			name := strings.trim_space(ui.field_string(&m.rename))
			if name != "" && name != wf.name {
				delete(wf.name)
				wf.name = strings.clone(name)
				workflows_changed(app, now = true)
			}
			m.renaming = 0
		case r.cancelled:
			m.renaming = 0
		}
	} else {
		sig := ui.nav_item("###wf_name", wf.name, "", 0, shown, em)
		if sig.clicked { workflow_show(app, wf.id) }
		if sig.double_clicked { workflow_rename_start(app, wf.id) }
		if ui.hovered_for(sig) {
			if ui.tooltip() { ui.tooltip_text("Double-click to rename") }
		}
	}
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.4)), font_size = math.round(em * 0.8), text_pad = em * 0.6})
		ui.label(fmt.tprintf("%s###wf_triggers", workflow_triggers_text(wf)))
	}
	ui.spacer(ui.px(em * 0.3))
}

@(private = "file")
workflow_duplicate :: proc(app: ^App, id: u64) {
	wf := workflows_find(&app.workflows, id)
	if wf == nil { return }
	copy_wf := flowgraph.entry_clone(wf^)
	delete(copy_wf.name)
	copy_wf.name = fmt.aprintf("%s (copy)", wf.name)
	new_id := workflows_add(&app.workflows, copy_wf)
	workflow_show(app, new_id)
	workflows_changed(app, now = true)
}

@(private = "file")
list_icon_button :: proc(id, glyph, tip: string, em: f32, enabled: bool) -> bool {
	ui.next({width = ui.px(math.round(em * 1.9)), height = ui.px(math.round(em * 1.9)), font_size = em * 1.05})
	return ui.icon_button(fmt.tprintf("wf_list_%s", id), glyph, tip = tip, disabled = !enabled).clicked && enabled
}

////////////////////////////////
// The inspector

workflow_inspector :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(math.round(em * WORKFLOW_INSPECTOR_EM)), height = ui.fill(), axis = .Y})
	if ui.column(id = "###wf_inspector") {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.scroll_y("###wf_inspector_scroll") { workflow_inspector_body(app, em) }
	}
}

@(private = "file")
workflow_inspector_body :: proc(app: ^App, em: f32) {
	m := &app.history_window.workflow_mode
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil { return }
	n: ^flowgraph.Node
	if len(m.selection) == 1 { n = flowgraph.graph_node(&wf.graph, m.selection[0]) }
	ui.spacer(ui.px(em * 0.6))
	if n == nil {
		workflow_triggers_edit(app, wf, em)
		return
	}
	def := &CATALOG.nodes[n.kind]
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 2.2)), axis = .X, cross = .Center})
	if ui.row(id = "###wf_node_head") {
		ui.spacer(ui.px(em * 0.8))
		ui.icon(def.icon, em * 1.6)
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = math.round(em * 1.1), text_pad = 0})
		ui.label(fmt.tprintf("%s###wf_node_title", def.title))
	}
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.84), text_pad = em * 0.8})
		ui.paragraph(fmt.tprintf("%s###wf_node_group", node_what(n)))
	}
	if l, has := m.last[n.id]; has && l.message != "" {
		if ui.tags(l.state == .Failed ? "bad" : "weak") {
			ui.next({width = ui.fill(), font_size = math.round(em * 0.84), text_pad = em * 0.8})
			ui.paragraph(fmt.tprintf("Last run: %s###wf_node_last", l.message))
		}
	}
	if Node_Kind(n.kind) == .Capture {
		workflow_triggers_edit(app, wf, em)
		return
	}
	if len(def.params) == 0 { return }
	ui.spacer(ui.px(em * 0.5))
	res: ui.Node_Inspector_Result
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###wf_params_row") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		res = ui.node_inspector("###wf_params", &m.inspector, &CATALOG, n, {
			user = app,
			lists = proc(user: rawptr, n: ^flowgraph.Node, param: flowgraph.Param_Def) -> []string {
				return (^App)(user).uploaders.names   // (the only List: the Upload node's host)
			},
			default_text = fmt.tprintf("The default: %s", app.settings.uploader),
		})
		ui.spacer(ui.px(em * 0.8))
	}
	m.typing ||= res.typing
	if res.changed >= 0 {
		// (a slider dragged is one step of undo; the file is written a little after the last change)
		if res.new_step { workflow_undo_push(app, wf) }
		flowgraph.param_set(n, res.changed, res.value)
		workflows_changed(app, now = false)
		ui.timer_set(m.save_key, WORKFLOW_SAVE_DELAY_MS)
	}
	if res.pick_folder >= 0 {
		folder := n.params[res.pick_folder].text
		app_pick_folder(app, folder != "" ? folder : app.settings.folder, wf.id, n.id)
	}
	ui.spacer(ui.px(em * 1))
	ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###wf_reset_row") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({height = ui.px(math.round(em * 1.9))})
		if ui.button_icon("###wf_reset", lucide.REFRESH_CW, "Reset").clicked {
			workflow_undo_push(app, wf)
			flowgraph.node_params_default(&CATALOG, n)
			m.inspector.node = 0
			workflows_changed(app, now = true)
		}
	}
}

// What a kind of node does, in a sentence.
@(private = "file")
node_what :: proc(n: ^flowgraph.Node) -> string {
	def := &CATALOG.nodes[n.kind]
	#partial switch Node_Kind(n.kind) {
	case .Capture:        return "Where the workflow starts: the picture of the capture."
	case .Annotate:       return "Opens the picture in the editor. Done sends its picture on and fires \"done\"; Cancel stops this branch and fires \"cancelled\"."
	case .Condition:      return "Sends the picture to \"yes\" or to \"no\"."
	case .Notify:         return "One notification at the end of the run: its title, and what comes in or a summary. Linked to \"when\", it waits for that action."
	case .Add_To_History: return "Keeps the file, the address or the text that comes in, in the history."
	}
	if def.effect { return fmt.tprintf("%s. Off in a preview. Linked to \"when\", it waits for that action (an editor's Done or Cancel).", def.group) }
	return fmt.tprintf("%s: makes a new picture; the others that read this one keep it as it is.", def.group)
}

// The captures that run the workflow: a toggle each, with its keys; one taken here leaves the workflow that had it.
@(private = "file")
workflow_triggers_edit :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.8)), font_size = math.round(em * 1.05), text_pad = em * 0.8})
	ui.label(fmt.tprintf("%s###wf_name_title", wf.name))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), font_size = math.round(em * 0.84), text_pad = em * 0.8})
		ui.paragraph("The captures that run this workflow. Each capture runs one workflow: one chosen here leaves the workflow that had it.###wf_triggers_note")
	}
	for t in Trigger {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = fmt.tprintf("###wf_trigger_%d", int(t))) { workflow_trigger(app, wf, t, em) }
	}
}

// One trigger's toggle and what it says.
@(private = "file")
workflow_trigger :: proc(app: ^App, wf: ^flowgraph.Graph_Entry, t: Trigger, em: f32) {
	was := t in workflow_triggers(wf)
	on := was
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), text_pad = em * 0.8})
	ui.toggle("###on", TRIGGER_TEXT[t], &on)
	if on != was {
		workflows_bind(&app.workflows, wf.id, t, on)
		workflows_changed(app, now = true)
	}
	what := trigger_keys_text(app, t)
	if other := workflows_for(&app.workflows, t); other != nil && other.id != wf.id {
		what = fmt.tprintf("%s; runs \"%s\" now", what, other.name)
	}
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.4)), font_size = math.round(em * 0.8), text_pad = em * 2.6})
		ui.label(fmt.tprintf("%s###keys", what))
	}
}

// The keys and the command that start a trigger.
@(private = "file")
trigger_keys_text :: proc(app: ^App, t: Trigger) -> string {
	command := fmt.tprintf("cliche --%s", TRIGGER_NAMES[t])
	action: Shortcut_Action
	switch t {
	case .Region: action = .Region
	case .Screen: action = .Screen
	case .Window: action = .Window
	case .Qr:     action = .Qr
	case .Ocr:    action = .Ocr
	case .Edit:   return command
	}
	if keys := shortcut_keys(app, action); keys != "" { return fmt.tprintf("%s, %s", keys, command) }
	return command
}
