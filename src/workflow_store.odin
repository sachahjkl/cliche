package cliche

// The workflows' file: <config dir>/cliche/workflows.json (core:encoding/json). The worker reads it at the start
// (Job_Workflows_Load); after each change the interface's thread makes its text and the worker writes it (Job_Write), at
// the end of a gesture, not at each frame (workflow_app.odin). A missing file gives the default workflows; a file that
// cannot be read gives them too, is kept aside as workflows.json.broken, and the Workflows mode says why.
//
//   {"version": 1, "workflows": [{"id": 1, "name": "Screenshot", "triggers": ["region"], "next_id": 5,
//     "nodes": [{"id": 1, "kind": "resize", "x": 0, "y": 120, "params": {"percent": 50, "color": "#000000ff"}}],
//     "links": [{"from": 1, "from_port": 0, "to": 2, "to_port": 0}]}]}
//
// A parameter is written under its name: a number (Int, Float, Choice), true / false (Bool), "#rrggbbaa" (Color), a
// string (Text, Folder, Uploader). What the file lacks takes its default; what it has that cliche does not know is
// dropped (a node of an unknown kind, a link that is not valid).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "gt:platform"

WORKFLOWS_FILE_VERSION :: 1

workflows_file :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/workflows.json"}, allocator)
}

// The workflows of the file, or the defaults (on the worker: it reads the disk). problem: why the file was not used
// (owned; "" none).
workflows_load :: proc() -> (ws: Workflows, problem: string) {
	return workflows_load_from(workflows_file())
}

// The same, from the file at `path` (a test's file).
workflows_load_from :: proc(path: string) -> (ws: Workflows, problem: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		if os.exists(path) { return workflows_default(), fmt.aprintf("%s cannot be read: the default workflows are in its place.", path) }
		return workflows_default(), ""
	}
	list, why := workflows_parse(string(data))
	if why == "" { return list, "" }
	workflows_free(&list)
	aside := strings.concatenate({path, ".broken"}, context.temp_allocator)
	_ = os.rename(path, aside)
	return workflows_default(), fmt.aprintf("%s cannot be read (%s): it is kept as %s, and the default workflows are in its place.", path, why, aside)
}

////////////////////////////////
// Writing

// The file's text (owned).
workflows_text :: proc(ws: ^Workflows) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "{{\n  \"version\": %d,\n  \"workflows\": [", WORKFLOWS_FILE_VERSION)
	for &wf, wi in ws.list {
		strings.write_string(&b, wi == 0 ? "\n    {" : ",\n    {")
		fmt.sbprintf(&b, "\"id\": %d, \"name\": ", wf.id)
		json_string(&b, wf.name)
		strings.write_string(&b, ", \"triggers\": [")
		first := true
		for t in Trigger {
			if t not_in wf.triggers { continue }
			if !first { strings.write_string(&b, ", ") }
			json_string(&b, TRIGGER_NAMES[t])
			first = false
		}
		fmt.sbprintf(&b, "], \"next_id\": %d,\n      \"nodes\": [", wf.next_id)
		for &n, ni in wf.nodes {
			strings.write_string(&b, ni == 0 ? "\n        {" : ",\n        {")
			fmt.sbprintf(&b, "\"id\": %d, \"kind\": \"%s\", \"x\": %.1f, \"y\": %.1f, \"params\": {{", n.id, NODE_NAMES[n.kind], n.pos.x, n.pos.y)
			for d, pi in NODE_DEFS[n.kind].params {
				if pi > 0 { strings.write_string(&b, ", ") }
				json_string(&b, d.name)
				strings.write_string(&b, ": ")
				p := n.params[pi]
				switch d.type {
				case .Int, .Choice: fmt.sbprintf(&b, "%d", i64(p.number))
				case .Float:        fmt.sbprintf(&b, "%g", p.number)
				case .Bool:         strings.write_string(&b, p.number != 0 ? "true" : "false")
				case .Color:        fmt.sbprintf(&b, "\"#%02x%02x%02x%02x\"", p.color.r, p.color.g, p.color.b, p.color.a)
				case .Text, .Folder, .Uploader: json_string(&b, p.text)
				}
			}
			strings.write_string(&b, "}}")   // (its parameters, then the node)
		}
		strings.write_string(&b, len(wf.nodes) > 0 ? "\n      ],\n      \"links\": [" : "],\n      \"links\": [")
		for l, li in wf.links {
			if li > 0 { strings.write_string(&b, ", ") }
			fmt.sbprintf(&b, "{{\"from\": %d, \"from_port\": %d, \"to\": %d, \"to_port\": %d}}", l.from_node, l.from_port, l.to_node, l.to_port)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, len(ws.list) > 0 ? "\n  ]\n}\n" : "]\n}\n")
	return strings.to_string(b)
}

// `s` as a JSON string, quoted and escaped.
@(private = "file")
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 { fmt.sbprintf(b, "\\u%04x", int(c)) } else { strings.write_rune(b, c) }
		}
	}
	strings.write_byte(b, '"')
}

////////////////////////////////
// Reading

// The workflows of `text`. why: "" when it reads; else what is wrong, and `ws` holds what was read so far (to free).
workflows_parse :: proc(text: string) -> (ws: Workflows, why: string) {
	root, err := json.parse(text, allocator = context.temp_allocator)
	if err != .None { return ws, fmt.tprintf("not JSON: %v", err) }
	top, is_object := root.(json.Object)
	if !is_object { return ws, "not an object" }
	if v, has := top["version"]; has {
		if version := json_int(v); version > WORKFLOWS_FILE_VERSION { return ws, fmt.tprintf("version %d is newer than this cliche's", version) }
	}
	list, is_array := top["workflows"].(json.Array)
	if !is_array { return ws, "no list of workflows" }
	bound: Trigger_Set
	for item in list {
		o, ok := item.(json.Object)
		if !ok { return ws, "a workflow is not an object" }
		wf := Workflow{id = u64(json_int(o["id"])), name = strings.clone(json_text(o["name"]))}
		if wf.name == "" { wf.name = strings.clone("Workflow") }
		if triggers, has := o["triggers"].(json.Array); has {
			for t in triggers {
				name := json_text(t)
				for tn, trig in TRIGGER_NAMES {
					// (a trigger runs one workflow: the first that names it)
					if tn == name && trig not_in bound { wf.triggers += {trig}; bound += {trig} }
				}
			}
		}
		if nodes, has := o["nodes"].(json.Array); has {
			for node_item in nodes {
				no, is_node := node_item.(json.Object)
				if !is_node { continue }
				n, known := node_parse(no)
				if !known { continue }
				if workflow_node(&wf, n.id) != nil || n.id == 0 { node_params_free(&n); continue }
				append(&wf.nodes, n)
				wf.next_id = max(wf.next_id, n.id)
			}
		}
		wf.next_id = max(wf.next_id, u64(json_int(o["next_id"])))
		if links, has := o["links"].(json.Array); has {
			for link_item in links {
				lo, is_link := link_item.(json.Object)
				if !is_link { continue }
				l := Workflow_Link{
					from_node = u64(json_int(lo["from"])), from_port = u32(json_int(lo["from_port"])),
					to_node = u64(json_int(lo["to"])), to_port = u32(json_int(lo["to_port"])),
				}
				_, _ = workflow_link(&wf, l)   // (one that is not valid is dropped)
			}
		}
		if wf.id == 0 || workflows_find(&ws, wf.id) != nil { wf.id = ws.next_id + 1 }
		ws.next_id = max(ws.next_id, wf.id)
		append(&ws.list, wf)
	}
	ws.version += 1
	return ws, ""
}

// A node of the file. known false: its kind is not one of cliche's.
@(private = "file")
node_parse :: proc(o: json.Object) -> (n: Workflow_Node, known: bool) {
	name := json_text(o["kind"])
	for kn, k in NODE_NAMES {
		if kn == name { n.kind, known = k, true }
	}
	if !known { return }
	n.id = u64(json_int(o["id"]))
	n.pos = {f32(json_float(o["x"])), f32(json_float(o["y"]))}
	node_params_default(&n)
	params, has := o["params"].(json.Object)
	if !has { return }
	for d, i in NODE_DEFS[n.kind].params {
		v, given := params[d.name]
		if !given { continue }
		p := &n.params[i]
		switch d.type {
		case .Int, .Choice, .Float:
			if f, is_number := json_number(v); is_number { p.number = f }
		case .Bool:
			if b, is_bool := v.(json.Boolean); is_bool { p.number = b ? 1 : 0 }
		case .Color:
			if c, read := color_parse(json_text(v)); read { p.color = c }
		case .Text, .Folder, .Uploader:
			if s, is_string := v.(json.String); is_string {
				delete(p.text)
				p.text = strings.clone(string(s))
			}
		}
	}
	return
}

// "#rrggbb" or "#rrggbbaa".
color_parse :: proc(s: string) -> (c: [4]u8, ok: bool) {
	if !strings.has_prefix(s, "#") || (len(s) != 7 && len(s) != 9) { return }
	c.a = 255
	for i in 0 ..< (len(s) - 1) / 2 {
		v, read := strconv.parse_uint(s[1 + i * 2:][:2], 16)
		if !read { return {}, false }
		c[i] = u8(v)
	}
	return c, true
}

@(private = "file")
json_number :: proc(v: json.Value) -> (f: f64, ok: bool) {
	#partial switch x in v {
	case json.Integer: return f64(x), true
	case json.Float:   return f64(x), true
	}
	return 0, false
}

@(private = "file")
json_float :: proc(v: json.Value) -> f64 {
	f, _ := json_number(v)
	return f
}

@(private = "file")
json_int :: proc(v: json.Value) -> i64 {
	f, _ := json_number(v)
	return f < 0 ? 0 : i64(f)
}

@(private = "file")
json_text :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return string(s)
}
