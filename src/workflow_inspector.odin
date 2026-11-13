package cliche

// The sides of the Workflows mode (workflow_view.odin): the list of workflows on the left, the inspector on the right.
// The inspector draws a node's parameters from its kind's schema (Param_Def), with the toolkit's widgets: a slider and
// its field for a number, a toggle, a colour picker, a segmented choice or a list, a text field, a folder and its
// dialog (on the worker), the uploaders. With no node selected, it shows the workflow: its name and the captures that
// run it.

import "core:fmt"
import "core:math"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"

Workflow_Inspector :: struct {
	node:        u64,     // the node the fields below were made for (0: made again at the next build)
	texts:       [NODE_PARAMS_MAX]ui.Text_Field,
	color:       ui.Color_Pick,
	color_param: int,     // the parameter whose colour picker is open (-1: none)
	undo_key:    [2]u64,  // the node and parameter (+1) of the last step of undo: a slider dragged is one step
	focus_due:   bool,
}

workflow_inspector_free :: proc(ins: ^Workflow_Inspector) {
	for &f in ins.texts { ui.field_destroy(&f) }
	ui.color_pick_destroy(&ins.color)
}

// The folder chosen in the system's dialog for a Save node (app_pick_folder).
workflow_folder_chosen :: proc(app: ^App, workflow, node: u64, path: string) {
	wf := workflows_find(&app.workflows, workflow)
	if wf == nil || path == "" { return }
	n := workflow_node(wf, node)
	p := n != nil ? node_param(n, "folder") : nil
	if p == nil { return }
	workflow_undo_push(app, wf)
	delete(p.text)
	p.text = strings.clone(path)
	app.history_window.workflow_mode.inspector.node = 0   // (its field shows the new folder)
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
		for &wf in app.workflows.list { workflow_list_item(app, &wf, em) }
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
workflow_list_item :: proc(app: ^App, wf: ^Workflow, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = fmt.tprintf("###wf_item_%d", wf.id)) { workflow_list_item_body(app, wf, em) }
}

@(private = "file")
workflow_list_item_body :: proc(app: ^App, wf: ^Workflow, em: f32) {
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
	copy_wf := workflow_clone(wf^)
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
	ins := &m.inspector
	wf := workflows_find(&app.workflows, m.shown)
	if wf == nil { return }
	n: ^Workflow_Node
	if len(m.selection) == 1 { n = workflow_node(wf, m.selection[0]) }
	if n == nil || n.id != ins.node {
		// (another node: its fields show its values)
		ins.node = n != nil ? n.id : 0
		ins.color_param = -1
		ins.undo_key = {}
		if n != nil {
			for d, i in NODE_DEFS[n.kind].params {
				if d.type == .Text || d.type == .Folder { ui.field_set(&ins.texts[i], n.params[i].text) }
			}
		}
	}
	ui.spacer(ui.px(em * 0.6))
	if n == nil {
		workflow_triggers(app, wf, em)
		return
	}
	def := NODE_DEFS[n.kind]
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
	if n.kind == .Capture {
		workflow_triggers(app, wf, em)
		return
	}
	for d, i in def.params {
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = fmt.tprintf("###wf_param_%d", i)) {
			if d.type != .Bool {
				ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.6)), text_pad = em * 0.8})
				ui.label(fmt.tprintf("%s###title", d.title))
			}
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
			if ui.row(id = "###control") {
				ui.spacer(ui.px(em * 0.8))
				workflow_param(app, wf, n, i, d, em)
				ui.spacer(ui.px(em * 0.8))
			}
		}
	}
	if len(def.params) > 0 {
		ui.spacer(ui.px(em * 1))
		ui.next({width = ui.children_sum(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###wf_reset_row") {
			ui.spacer(ui.px(em * 0.8))
			ui.next({height = ui.px(math.round(em * 1.9))})
			if ui.button_icon("###wf_reset", lucide.REFRESH_CW, "Reset").clicked {
				workflow_undo_push(app, wf)
				node_params_default(n)
				ins.node = 0
				workflows_changed(app, now = true)
			}
		}
	}
}

// What a kind of node does, in a sentence.
@(private = "file")
node_what :: proc(n: ^Workflow_Node) -> string {
	def := NODE_DEFS[n.kind]
	switch {
	case n.kind == .Capture:     return "Where the workflow starts: the picture of the capture."
	case n.kind == .Annotate:    return "Opens the picture in the editor. The workflow goes on with Done; closing the editor stops this branch."
	case n.kind == .Condition:   return "Sends the picture to \"yes\" or to \"no\"."
	case n.kind == .Notify:      return "One notification at the end of the run: its title, and what comes in or a summary."
	case n.kind == .Add_To_History: return "Keeps the file, the address or the text that comes in, in the history."
	case def.effect:             return fmt.tprintf("%s. Off in a preview.", NODE_GROUP_TEXT[def.group])
	}
	return fmt.tprintf("%s: makes a new picture; the others that read this one keep it as it is.", NODE_GROUP_TEXT[def.group])
}

// One parameter's control.
@(private = "file")
workflow_param :: proc(app: ^App, wf: ^Workflow, n: ^Workflow_Node, i: int, d: Param_Def, em: f32) {
	m := &app.history_window.workflow_mode
	ins := &m.inspector
	p := &n.params[i]
	switch d.type {
	case .Int, .Float:
		// (a copy: param_change keeps the value before the change for its undo)
		v := p.number
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		if ui.number("###number", &v, lo = f64(d.lo), hi = f64(d.hi), step = f64(d.step), unit = d.unit, track = true) {
			param_change(app, wf, n, i)
			p.number = v
		}
	case .Bool:
		on := p.number != 0
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		ui.toggle("###toggle", d.title, &on)
		if on != (p.number != 0) {
			param_change(app, wf, n, i)
			p.number = on ? 1 : 0
		}
	case .Choice:
		chosen := clamp(int(p.number), 0, max(len(d.choices) - 1, 0))
		changed: bool
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		if len(d.choices) <= 3 { changed = ui.segmented("choice", d.choices, &chosen) } else { changed = ui.dropdown("###choice", d.choices, &chosen) }
		if changed {
			param_change(app, wf, n, i)
			p.number = f64(chosen)
		}
	case .Color:
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###color_col") {
			open := ins.color_param == i
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
			if ui.button_icon("###color", lucide.PALETTE, color_text(p.color)).clicked {
				ins.color_param = open ? -1 : i
				if !open { ui.color_pick_set(&ins.color, srgba_of(p.color), {format = .Hex}) }
			}
			if open {
				ui.spacer(ui.px(em * 0.4))
				if ui.color_picker("###picker", &ins.color) {
					param_change(app, wf, n, i)
					p.color = rgba8_of(ui.color_pick_rgba(&ins.color))
				}
			}
		}
	case .Text, .Folder:
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		r := ui.line_edit("###text", &ins.texts[i], d.placeholder, clearable = true)
		m.typing |= r.focused
		if r.changed {
			param_change(app, wf, n, i)
			delete(p.text)
			p.text = strings.clone(strings.trim_space(ui.field_string(&ins.texts[i])))
		}
		if d.type == .Folder {
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.8), height = ui.px(math.round(em * 1.9)), radius = em * 0.4})
			if ui.button("Choose…###choose").clicked {
				app_pick_folder(app, p.text != "" ? p.text : app.settings.folder, wf.id, n.id)
			}
		}
	case .Uploader:
		names := app.uploaders.names
		items := make([]string, len(names) + 1, context.temp_allocator)
		items[0] = fmt.tprintf("The default: %s", app.settings.uploader)
		chosen := 0
		for name, k in names {
			items[k + 1] = name
			if name == p.text { chosen = k + 1 }
		}
		ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9))})
		if ui.dropdown("###uploader", items, &chosen) {
			param_change(app, wf, n, i)
			delete(p.text)
			p.text = chosen > 0 ? strings.clone(names[chosen - 1]) : ""
		}
	}
}

// A parameter is about to change: one step of undo per parameter changed in a row (a slider dragged is one), and the
// file written a little after the last change.
@(private = "file")
param_change :: proc(app: ^App, wf: ^Workflow, n: ^Workflow_Node, i: int) {
	m := &app.history_window.workflow_mode
	key := [2]u64{n.id, u64(i + 1)}
	if m.inspector.undo_key != key {
		workflow_undo_push(app, wf)
		m.inspector.undo_key = key
	}
	workflows_changed(app, now = false)
	ui.timer_set(m.save_key, WORKFLOW_SAVE_DELAY_MS)
}

// The captures that run the workflow: a toggle each, with its keys; one taken here leaves the workflow that had it.
@(private = "file")
workflow_triggers :: proc(app: ^App, wf: ^Workflow, em: f32) {
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
workflow_trigger :: proc(app: ^App, wf: ^Workflow, t: Trigger, em: f32) {
	on := t in wf.triggers
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), text_pad = em * 0.8})
	ui.toggle("###on", TRIGGER_TEXT[t], &on)
	if on != (t in wf.triggers) {
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

@(private = "file")
srgba_of :: proc(c: [4]u8) -> ui.Srgba {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

@(private = "file")
rgba8_of :: proc(c: ui.Srgba) -> [4]u8 {
	return {u8(math.round(clamp(c.r, 0, 1) * 255)), u8(math.round(clamp(c.g, 0, 1) * 255)), u8(math.round(clamp(c.b, 0, 1) * 255)), u8(math.round(clamp(c.a, 0, 1) * 255))}
}
