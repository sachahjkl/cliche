package cliche

// ShareX's syntax in a custom uploader's texts: `{name}` or `{name:param|param}`, nested, with `\` before a `{`, `}`, `|` or
// `\` that is only a character (https://getsharex.com/docs/custom-uploader). The parse is ShareX's own
// (ShareXSyntaxParser.cs), so a file reads the same here: an unescaped `|` or `}` outside a call ends the text.
//
// What each name gives here:
//   filename                 the file's name (URL-encoded in an address)
//   input                    "" (cliche uploads files: there is no text input)
//   random:a|b|c             one of them
//   select:a|b|c             the first (cliche shows no window to choose)
//   inputbox:title|default   the default text (no window either)
//   outputbox:...            "" (no window)
//   base64:text              the text in Base64
//   response                 the answer's body
//   responseurl              the address that answered, after the redirects
//   header:name              a header of the answer (names without case)
//   json:path, json:input|path       a JSONPath subset: `$.` optional, `a.b`, `[0]`, `['key']`
//   xml:xpath, xml:input|xpath       an XPath subset: `/a/b`, `//b`, `*`, `[n]`, a last `@attr` or `text()`
//   regex:pattern|group, regex:input|pattern|group   core:text/regex (no lookaround), a group by number or by name
// The answer's names are refused in the request (no answer yet).

import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/xml"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "gt:ascii"
import http "gt:http"
import i18n "gt:i18n"

// An upload's answer, as the syntax reads it.
Answer :: struct {
	status:  int,
	text:    string,
	url:     string,
	headers: []http.Header,
}

// What the syntax of one text reads.
Syntax :: struct {
	file_name:  string,
	url_encode: bool,      // {filename} and {input} percent-encoded: the text is an address
	answer:     ^Answer,   // nil: the request is being built, there is no answer yet
}

// `text` with its syntax expanded (allocator). problem: what went wrong, in the temp allocator ("": nothing).
syntax_expand :: proc(text: string, s: Syntax, allocator := context.temp_allocator) -> (out: string, problem: string) {
	if text == "" { return "", "" }
	e := Expander{syntax = s}
	parsed, _ := expand_from(&e, text, false, 0)
	if e.problem != "" { return "", e.problem }
	return strings.clone(parsed, allocator), ""
}

@(private = "file")
Expander :: struct {
	syntax:  Syntax,
	problem: string,   // the first one; the rest of the text is still parsed, its result dropped
}

// ShareXSyntaxParser.Parse: from `start`, up to an unescaped `}` or `|` (end: its index), calling what is between braces.
// in_call: the text is a call's name, and a `:` starts its parameters.
@(private = "file")
expand_from :: proc(e: ^Expander, text: string, in_call: bool, start: int) -> (out: string, end: int) {
	b := strings.builder_make(context.temp_allocator)
	escape := false
	i := start
	for ; i < len(text); i += 1 {
		c := text[i]
		if !escape {
			switch {
			case c == '{':
				parsed: string
				parsed, i = expand_from(e, text, true, i + 1)
				strings.write_string(&b, parsed)
				continue
			case c == '}' || c == '|':
				return finish(e, &b, in_call, nil), i
			case c == '\\':
				escape = true
				continue
			case in_call && c == ':':
				params := make([dynamic]string, context.temp_allocator)
				for {
					p: string
					p, i = expand_from(e, text, false, i + 1)
					append(&params, p)
					if i >= len(text) || text[i] != '|' { break }
				}
				return call(e, strings.to_string(b), params[:]), i
			}
		}
		escape = false
		strings.write_byte(&b, c)
	}
	return finish(e, &b, in_call, nil), i
}

@(private = "file")
finish :: proc(e: ^Expander, b: ^strings.Builder, in_call: bool, params: []string) -> string {
	return in_call ? call(e, strings.to_string(b^), params) : strings.to_string(b^)
}

@(private = "file")
fail :: proc(e: ^Expander, problem: string) -> string {
	if e.problem == "" { e.problem = problem }
	return ""
}

@(private = "file")
call :: proc(e: ^Expander, name: string, params: []string) -> string {
	s := e.syntax
	param :: proc(list: []string, i: int) -> string { return i < len(list) ? list[i] : "" }
	n := ascii.lower(name, context.temp_allocator)
	answer_names := n == "response" || n == "responseurl" || n == "header" || n == "json" || n == "xml" || n == "regex"
	if answer_names && s.answer == nil {
		return fail(e, fmt.tprintf(i18n.tr("{%s} reads the host's answer: it is only for the URLs read from it"), name))
	}
	switch n {
	case "filename":    return s.url_encode ? url_encode(s.file_name) : s.file_name
	case "input":       return ""
	case "random":
		if len(params) == 0 { return fail(e, i18n.tr("{random} needs values: {random:a|b}")) }
		return rand.choice(params)
	case "select":      return param(params, 0)
	case "inputbox":    return param(params, 1)
	case "outputbox":   return ""
	case "base64":
		text := param(params, 0)
		if text == "" { return "" }
		return base64.encode(transmute([]u8)text, allocator = context.temp_allocator)
	case "response":    return s.answer.text
	case "responseurl": return s.answer.url
	case "header":
		value, _ := http.header_value(s.answer.headers, param(params, 0))
		return value
	case "json":
		input, path := s.answer.text, param(params, 0)
		if len(params) > 1 { input, path = params[0], params[1] }
		if input == "" || path == "" { return "" }
		text, problem := json_select(input, path)
		if problem != "" { return fail(e, problem) }
		return text
	case "xml":
		input, path := s.answer.text, param(params, 0)
		if len(params) > 1 { input, path = params[0], params[1] }
		if input == "" || path == "" { return "" }
		text, problem := xml_select(input, path)
		if problem != "" { return fail(e, problem) }
		return text
	case "regex":
		input, pattern, group := s.answer.text, param(params, 0), param(params, 1)
		if len(params) > 2 { input, pattern, group = params[0], params[1], params[2] }
		if input == "" || pattern == "" { return "" }
		text, problem := regex_select(input, pattern, group)
		if problem != "" { return fail(e, problem) }
		return text
	}
	if name == "" { return fail(e, i18n.tr("an empty {} in the uploader")) }
	return fail(e, fmt.tprintf(i18n.tr("the uploader uses {%s}, which cliche does not know"), name))
}

// Percent-encoding of everything but A-Z a-z 0-9 - _ . ~ (ShareX's URLHelpers.URLEncode).
url_encode :: proc(s: string, allocator := context.temp_allocator) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(0, len(s), allocator)
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~': strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
		}
	}
	return strings.to_string(b)
}

// JSON

// The value at `path` in the JSON `text`, as text (temp allocator): a string as it is, a number or a boolean as written,
// null or nothing there "". An object or an array is a problem (ShareX refuses them too).
json_select :: proc(text, path: string) -> (out: string, problem: string) {
	value, err := json.parse(transmute([]u8)text, .JSON5, parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return "", i18n.tr("the host's answer is not JSON") }
	p := path
	if strings.has_prefix(p, "$") { p = p[1:] }
	v := value
	for len(p) > 0 {
		switch p[0] {
		case '.':
			p = p[1:]
		case '[':
			close := strings.index_byte(p, ']')
			if close < 0 { return "", fmt.tprintf(i18n.tr("the JSON path %q has a [ with no ]"), path) }
			inner := strings.trim_space(p[1:close])
			p = p[close + 1:]
			if len(inner) >= 2 && (inner[0] == '\'' || inner[0] == '"') && inner[len(inner) - 1] == inner[0] {
				obj, is_obj := v.(json.Object)
				if !is_obj { return "", "" }
				v = obj[inner[1:len(inner) - 1]] or_else nil
			} else {
				index, ok := strconv.parse_int(inner, 10)
				if !ok { return "", fmt.tprintf(i18n.tr("the JSON path %q has an index cliche does not read: [%s]"), path, inner) }
				arr, is_arr := v.(json.Array)
				if !is_arr { return "", "" }
				if index < 0 { index += len(arr) }
				if index < 0 || index >= len(arr) { return "", "" }
				v = arr[index]
			}
		case:
			end := strings.index_any(p, ".[")
			key := end < 0 ? p : p[:end]
			p = end < 0 ? "" : p[end:]
			obj, is_obj := v.(json.Object)
			if !is_obj { return "", "" }
			v = obj[key] or_else nil
		}
		if v == nil { return "", "" }
	}
	switch x in v {
	case json.String:  return string(x), ""
	case json.Integer: return fmt.tprintf("%d", x), ""
	case json.Float:   return fmt.tprintf("%v", x), ""
	case json.Boolean: return x ? "True" : "False", ""   // (as .NET writes them: ShareX's own)
	case json.Null:    return "", ""
	case json.Array, json.Object:
		return "", fmt.tprintf(i18n.tr("the JSON path %q is a list or an object, not a text"), path)
	}
	return "", ""
}

// XML

@(private = "file") XML_DOCUMENT :: max(xml.Element_ID)   // (the node above the root element, where a path starts)

// The text at `xpath` in the XML `text` (temp allocator): an element's text (all of it, children included), an
// attribute's value, or "" when nothing is there.
xml_select :: proc(text, xpath: string) -> (out: string, problem: string) {
	options := xml.Options{flags = {.Ignore_Unsupported, .Decode_SGML_Entities, .Unbox_CDATA}}
	quiet :: proc(pos: xml.Pos, format: string, args: ..any) {}
	doc, err := xml.parse(transmute([]u8)text, options, "", quiet, context.temp_allocator)
	if err != .None || doc == nil || doc.element_count == 0 { return "", i18n.tr("the host's answer is not XML") }
	nodes := make([dynamic]xml.Element_ID, context.temp_allocator)
	append(&nodes, XML_DOCUMENT)
	rest := xpath
	for len(rest) > 0 {
		descendant := false
		switch {
		case strings.has_prefix(rest, "//"): descendant, rest = true, rest[2:]
		case strings.has_prefix(rest, "/"):  rest = rest[1:]
		}
		end := strings.index_byte(rest, '/')
		step := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end:]
		if step == "" { return "", fmt.tprintf(i18n.tr("the XPath %q has an empty step"), xpath) }
		if descendant { nodes = xml_descendants(doc, nodes[:]) }
		if step[0] == '@' || step == "text()" {
			if rest != "" || len(nodes) == 0 { return "", "" }
			el := nodes[0]
			if el == XML_DOCUMENT { return "", "" }
			if step == "text()" { return xml_text(doc, el, false), "" }
			for a in doc.elements[el].attribs { if a.key == step[1:] { return a.val, "" } }
			return "", ""
		}
		name, position := step, 0
		if open := strings.index_byte(step, '['); open >= 0 {
			if !strings.has_suffix(step, "]") { return "", fmt.tprintf(i18n.tr("the XPath %q has a [ with no ]"), xpath) }
			ok: bool
			position, ok = strconv.parse_int(step[open + 1:len(step) - 1], 10)
			if !ok || position < 1 { return "", fmt.tprintf(i18n.tr("the XPath %q has a condition cliche does not read: %s"), xpath, step[open:]) }
			name = step[:open]
		}
		next := make([dynamic]xml.Element_ID, context.temp_allocator)
		for parent in nodes {
			seen := 0
			for child in xml_children(doc, parent) {
				if name != "*" && doc.elements[child].ident != name { continue }
				seen += 1
				if position == 0 || seen == position { append(&next, child) }
			}
		}
		nodes = next
	}
	if len(nodes) == 0 || nodes[0] == XML_DOCUMENT { return "", "" }
	return xml_text(doc, nodes[0], true), ""
}

@(private = "file")
xml_children :: proc(doc: ^xml.Document, el: xml.Element_ID) -> []xml.Element_ID {
	out := make([dynamic]xml.Element_ID, context.temp_allocator)
	if el == XML_DOCUMENT {
		append(&out, 0)
		return out[:]
	}
	for v in doc.elements[el].value {
		if child, is_child := v.(xml.Element_ID); is_child && doc.elements[child].kind == .Element { append(&out, child) }
	}
	return out[:]
}

// Each node and all below it, in document order: what `//` steps from.
@(private = "file")
xml_descendants :: proc(doc: ^xml.Document, nodes: []xml.Element_ID) -> [dynamic]xml.Element_ID {
	out := make([dynamic]xml.Element_ID, context.temp_allocator)
	for n in nodes { xml_walk(doc, n, &out) }
	return out
}

@(private = "file")
xml_walk :: proc(doc: ^xml.Document, el: xml.Element_ID, into: ^[dynamic]xml.Element_ID) {
	append(into, el)
	for child in xml_children(doc, el) { xml_walk(doc, child, into) }
}

@(private = "file")
xml_text :: proc(doc: ^xml.Document, el: xml.Element_ID, deep: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	xml_write_text(doc, el, deep, &b)
	return strings.to_string(b)
}

@(private = "file")
xml_write_text :: proc(doc: ^xml.Document, el: xml.Element_ID, deep: bool, into: ^strings.Builder) {
	for v in doc.elements[el].value {
		switch x in v {
		case string:         strings.write_string(into, x)
		case xml.Element_ID: if deep && doc.elements[x].kind == .Element { xml_write_text(doc, x, deep, into) }
		}
	}
}

// Regular expressions

// The first match of `pattern` in `text`: the whole match, or its group `group` (a number, or a name given as
// (?<name>...), (?'name'...) or (?P<name>...)).
regex_select :: proc(text, pattern, group: string) -> (out: string, problem: string) {
	plain, names := regex_names(pattern)
	re, err := regex.create(plain, {.Unicode}, context.temp_allocator, context.temp_allocator)
	if err != nil { return "", fmt.tprintf(i18n.tr("cliche cannot read the regular expression %q (no lookahead or lookbehind here)"), pattern) }
	capture, matched := regex.match(re, text, context.temp_allocator, context.temp_allocator)
	if !matched { return "", "" }
	index := 0
	if group != "" {
		number, is_number := strconv.parse_int(group, 10)
		switch {
		case is_number: index = number
		case group in names: index = names[group]
		case: return "", fmt.tprintf(i18n.tr("the regular expression %q has no group named %q"), pattern, group)
		}
	}
	if index < 0 || index >= len(capture.groups) { return "", "" }
	return capture.groups[index], ""
}

// `pattern` with its named groups made plain groups, and the number of each name. core:text/regex numbers groups as
// .NET does when no group is named; a pattern that mixes both is numbered left to right here (.NET numbers the named
// ones last).
@(private = "file")
regex_names :: proc(pattern: string) -> (plain: string, names: map[string]int) {
	names = make(map[string]int, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	count := 0
	in_class := false
	for i := 0; i < len(pattern); i += 1 {
		c := pattern[i]
		switch {
		case c == '\\' && i + 1 < len(pattern):
			strings.write_byte(&b, c)
			strings.write_byte(&b, pattern[i + 1])
			i += 1
			continue
		case in_class:
			if c == ']' { in_class = false }
		case c == '[':
			in_class = true
		case c == '(':
			rest := pattern[i + 1:]
			if !strings.has_prefix(rest, "?") {
				count += 1
				break
			}
			name_start, close := -1, byte(0)
			switch {
			case strings.has_prefix(rest, "?P<"):                                      name_start, close = 3, '>'
			case strings.has_prefix(rest, "?<") && !strings.has_prefix(rest, "?<=") && !strings.has_prefix(rest, "?<!"): name_start, close = 2, '>'
			case strings.has_prefix(rest, "?'"):                                       name_start, close = 2, '\''
			}
			if name_start < 0 { break }   // (a group that captures nothing, or a lookaround the compiler refuses)
			end := strings.index_byte(rest[name_start:], close)
			if end < 0 { break }
			count += 1
			names[rest[name_start:name_start + end]] = count
			strings.write_byte(&b, '(')
			i += 1 + name_start + end
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), names
}
