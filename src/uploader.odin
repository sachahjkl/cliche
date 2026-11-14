package cliche

// The Upload action: the picture sent to a host, the URL it answers given back. An uploader is described as ShareX's
// custom uploaders are, in a .sxcu file (JSON; https://getsharex.com/docs/custom-uploader), so a file made for ShareX
// works here as it is. The uploaders are the built-in ones (Litterbox; the URL shorteners is.gd and v.gd, which the
// Shorten URL node uses) and the .sxcu files of <config dir>/cliche/uploaders. Everything here that reads a file or the
// network runs on the worker.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "gt:ascii"
import "gt:fsx"
import http "gt:http"
import "gt:platform"
import i18n "gt:i18n"

// What a request's body is (ShareX's CustomUploaderBody). cliche sends a file only with Multipart_Form_Data and Binary,
// as ShareX does; the others are read, and refused at upload.
Uploader_Body :: enum u8 { None, Multipart_Form_Data, Form_Url_Encoded, Json, Xml, Binary }

UPLOADER_BODY_NAMES := [Uploader_Body]string{
	.None = "None", .Multipart_Form_Data = "MultipartFormData", .Form_Url_Encoded = "FormURLEncoded",
	.Json = "JSON", .Xml = "XML", .Binary = "Binary",
}

// What an uploader is for (ShareX's CustomUploaderDestinationType: flags).
Destination :: enum u8 { Image_Uploader, Text_Uploader, File_Uploader, Url_Shortener, Url_Sharing_Service }
Destinations :: bit_set[Destination; u8]

DESTINATION_NAMES := [Destination]string{
	.Image_Uploader = "ImageUploader", .Text_Uploader = "TextUploader", .File_Uploader = "FileUploader",
	.Url_Shortener = "URLShortener", .Url_Sharing_Service = "URLSharingService",
}

// ShareX's HttpMethod, in its order (a file may give the number).
UPLOADER_METHODS := [?]string{"GET", "POST", "PUT", "PATCH", "DELETE"}

// One uploader, as its .sxcu file says. Its strings and lists are the allocator's of uploader_parse: uploader_destroy.
// Parameters, Headers and Arguments are JSON objects, whose order core:encoding/json does not keep: they are sorted by
// name, so a request is the same at every upload.
Uploader :: struct {
	file:           string,         // the .sxcu file it was read from ("": built in)
	version:        string,         // the ShareX version that wrote it
	name:           string,         // its Name, else the host of its RequestURL
	destinations:   Destinations,
	method:         string,         // GET, POST, PUT, PATCH or DELETE
	request_url:    string,
	parameters:     []http.Param,   // added to the URL's query
	headers:        []http.Header,
	body:           Uploader_Body,
	arguments:      []http.Param,   // the text fields of a form
	file_form_name: string,         // the form field of the file
	data:           string,         // a JSON or XML body
	url:            string,         // the URL of the upload, read from the answer ("": the answer itself)
	thumbnail_url:  string,
	deletion_url:   string,
	error_message:  string,         // the host's reason, read from an answer that is not 2xx
}

uploader_destroy :: proc(u: ^Uploader, allocator := context.allocator) {
	context.allocator = allocator
	delete(u.file); delete(u.version); delete(u.name); delete(u.method); delete(u.request_url)
	for p in u.parameters { delete(p.name); delete(p.value) }
	delete(u.parameters)
	for h in u.headers { delete(h.name); delete(h.value) }
	delete(u.headers)
	for p in u.arguments { delete(p.name); delete(p.value) }
	delete(u.arguments)
	delete(u.file_form_name); delete(u.data); delete(u.url); delete(u.thumbnail_url); delete(u.deletion_url); delete(u.error_message)
	u^ = {}
}

uploaders_destroy :: proc(list: []Uploader, allocator := context.allocator) {
	for &u in list { uploader_destroy(&u, allocator) }
	delete(list, allocator)
}

// The built-in uploader: Litterbox, catbox.moe's host of temporary files. It takes anonymous uploads (no account, no key)
// by a multipart POST and answers the URL as text. Its files go after 72 hours: a screenshot sent by mistake does not stay
// online. catbox.moe's own .sxcu (permanent files) can be imported.
BUILTIN_UPLOADER_NAME :: "Litterbox (72 hours)"

BUILTIN_UPLOADER :: `{
  "Version": "17.0.0",
  "Name": "Litterbox (72 hours)",
  "DestinationType": "ImageUploader, FileUploader",
  "RequestMethod": "POST",
  "RequestURL": "https://litterbox.catbox.moe/resources/internals/api.php",
  "Body": "MultipartFormData",
  "Arguments": {
    "reqtype": "fileupload",
    "time": "72h"
  },
  "FileFormName": "fileToUpload"
}`

// The built-in URL shorteners: is.gd and v.gd, the same service under two names (v.gd's addresses go to a page that
// shows where they lead first). Anonymous, no key, an answer of the short address as text. A ShareX URL shortener
// (.sxcu) in the uploaders' folder is offered beside them.
BUILTIN_SHORTENER_NAME :: "is.gd"

BUILTIN_SHORTENERS :: [?]string{`{
  "Version": "17.0.0",
  "Name": "is.gd",
  "DestinationType": "URLShortener",
  "RequestMethod": "GET",
  "RequestURL": "https://is.gd/create.php",
  "Parameters": {
    "format": "simple",
    "url": "{input}"
  },
  "Body": "None"
}`, `{
  "Version": "17.0.0",
  "Name": "v.gd",
  "DestinationType": "URLShortener",
  "RequestMethod": "GET",
  "RequestURL": "https://v.gd/create.php",
  "Parameters": {
    "format": "simple",
    "url": "{input}"
  },
  "Body": "None"
}`}

// Whether `u` shortens addresses, and whether it takes files: a file that says neither is a picture's host.
uploader_shortens :: proc(u: Uploader) -> bool { return .Url_Shortener in u.destinations }

uploader_uploads :: proc(u: Uploader) -> bool {
	return u.destinations & {.Image_Uploader, .Text_Uploader, .File_Uploader} != {} || u.destinations == {}
}

// The names of the uploaders that upload (or, `shorteners`, that shorten), in the list's order (allocator).
uploaders_names :: proc(list: []Uploader, shorteners: bool, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(list), allocator)
	for u in list {
		if shorteners ? uploader_shortens(u) : uploader_uploads(u) { append(&out, strings.clone(u.name, allocator)) }
	}
	return out[:]
}

// The answer's body kept at most, and the time an upload may take.
UPLOAD_ANSWER_MAX :: 1 << 20
UPLOAD_TIMEOUT    :: 2 * time.Minute

// The oldest ShareX versions: before 12.4 the format differs (ShareX refuses those files too); up to 13.7.1 the syntax
// was $name$, rewritten as {name}.
@(private = "file") UNSUPPORTED_UP_TO :: "12.3.1"
@(private = "file") OLD_SYNTAX_UP_TO  :: "13.7.1"

// An uploader from the text of a .sxcu file. file: where it was read ("": built in). problem: why it cannot be used, in
// the temp allocator ("": none).
uploader_parse :: proc(text: []u8, file: string, allocator := context.allocator) -> (u: Uploader, problem: string) {
	value, err := json.parse(text, .JSON5, parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return {}, i18n.tr("the file is not JSON") }
	root, is_object := value.(json.Object)
	if !is_object { return {}, i18n.tr("the file is not a JSON object") }

	t: Uploader   // (temp allocator until it is whole; cloned at the end)
	t.version = json_text(root, "Version")
	if t.version == "" || version_compare(t.version, UNSUPPORTED_UP_TO) <= 0 {
		return {}, i18n.tr("the file is for a ShareX older than 12.4: export it again from a recent ShareX")
	}
	t.request_url = json_text(root, "RequestURL")
	if strings.trim_space(t.request_url) == "" { return {}, i18n.tr("the file has no RequestURL") }
	t.name = strings.trim_space(json_text(root, "Name"))
	t.file = file

	t.method = "POST"
	#partial switch m in root["RequestMethod"] {
	case json.String:
		t.method = ascii.upper(string(m), context.temp_allocator)
		if !slice.contains(UPLOADER_METHODS[:], t.method) { return {}, fmt.tprintf(i18n.tr("the RequestMethod %q is not one of ShareX's"), string(m)) }
	case json.Integer:
		if m < 0 || int(m) >= len(UPLOADER_METHODS) { return {}, i18n.tr("the RequestMethod is not one of ShareX's") }
		t.method = UPLOADER_METHODS[m]
	}

	#partial switch b in root["Body"] {
	case json.String:
		found := false
		for name, kind in UPLOADER_BODY_NAMES {
			if ascii.equal_fold(name, string(b)) { t.body, found = kind, true }
		}
		if !found { return {}, fmt.tprintf(i18n.tr("the Body %q is not one of ShareX's"), string(b)) }
	case json.Integer:
		if b < 0 || int(b) > int(max(Uploader_Body)) { return {}, i18n.tr("the Body is not one of ShareX's") }
		t.body = Uploader_Body(b)
	}

	#partial switch d in root["DestinationType"] {
	case json.String:
		for part in strings.split(string(d), ",", context.temp_allocator) {
			for name, kind in DESTINATION_NAMES {
				if ascii.equal_fold(name, strings.trim_space(part)) { t.destinations += {kind} }
			}
		}
	case json.Integer:
		for kind in Destination { if d & (1 << uint(kind)) != 0 { t.destinations += {kind} } }
	}

	t.parameters = json_pairs(root, "Parameters")
	header_pairs := json_pairs(root, "Headers")
	t.headers = make([]http.Header, len(header_pairs), context.temp_allocator)
	for p, i in header_pairs { t.headers[i] = {p.name, p.value} }
	t.arguments = json_pairs(root, "Arguments")
	t.file_form_name = json_text(root, "FileFormName")
	t.data = json_text(root, "Data")
	t.url = json_text(root, "URL")
	t.thumbnail_url = json_text(root, "ThumbnailURL")
	t.deletion_url = json_text(root, "DeletionURL")
	t.error_message = json_text(root, "ErrorMessage")

	if version_compare(t.version, OLD_SYNTAX_UP_TO) <= 0 { uploader_migrate(&t) }
	if t.name == "" { t.name = url_host(t.request_url) }
	if t.name == "" { t.name = "Uploader" }
	return uploader_clone(t, allocator), ""
}

// A text of the object: a string as it is, a number or a boolean as written, null or absent "" (temp allocator).
@(private = "file")
json_text :: proc(obj: json.Object, key: string) -> string {
	switch v in obj[key] {
	case json.String:  return string(v)
	case json.Integer: return fmt.tprintf("%d", v)
	case json.Float:   return fmt.tprintf("%v", v)
	case json.Boolean: return v ? "true" : "false"
	case json.Null, json.Array, json.Object:
	}
	return ""
}

// The names and texts of an object of the object, sorted by name (temp allocator).
@(private = "file")
json_pairs :: proc(obj: json.Object, key: string) -> []http.Param {
	inner, ok := obj[key].(json.Object)
	if !ok { return nil }
	out := make([]http.Param, len(inner), context.temp_allocator)
	i := 0
	for name in inner {
		out[i] = {name, json_text(inner, name)}
		i += 1
	}
	slice.sort_by(out, proc(a, b: http.Param) -> bool { return a.name < b.name })
	return out
}

@(private = "file")
uploader_clone :: proc(t: Uploader, allocator := context.allocator) -> (u: Uploader) {
	context.allocator = allocator
	u = t
	u.file = strings.clone(t.file); u.version = strings.clone(t.version); u.name = strings.clone(t.name)
	u.method = strings.clone(t.method); u.request_url = strings.clone(t.request_url)
	u.parameters = make([]http.Param, len(t.parameters))
	for p, i in t.parameters { u.parameters[i] = {strings.clone(p.name), strings.clone(p.value)} }
	u.headers = make([]http.Header, len(t.headers))
	for h, i in t.headers { u.headers[i] = {strings.clone(h.name), strings.clone(h.value)} }
	u.arguments = make([]http.Param, len(t.arguments))
	for p, i in t.arguments { u.arguments[i] = {strings.clone(p.name), strings.clone(p.value)} }
	u.file_form_name = strings.clone(t.file_form_name); u.data = strings.clone(t.data)
	u.url = strings.clone(t.url); u.thumbnail_url = strings.clone(t.thumbnail_url)
	u.deletion_url = strings.clone(t.deletion_url); u.error_message = strings.clone(t.error_message)
	return
}

// Up to ShareX 13.7.1 a call was $name$ and a brace was only a character: ShareX's MigrateOldSyntax, on every text.
@(private = "file")
uploader_migrate :: proc(t: ^Uploader) {
	old :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		start := true
		for i := 0; i < len(s); i += 1 {
			switch s[i] {
			case '$':
				strings.write_byte(&b, start ? '{' : '}')
				start = !start
				continue
			case '\\':
				i += 1   // (ShareX drops the backslash and the character after it)
				continue
			case '{', '}':
				strings.write_byte(&b, '\\')
			}
			strings.write_byte(&b, s[i])
		}
		return strings.to_string(b)
	}
	t.request_url = old(t.request_url)
	for &p in t.parameters { p.value = old(p.value) }
	for &h in t.headers { h.value = old(h.value) }
	for &a in t.arguments { a.value = old(a.value) }
	t.data, _ = strings.replace_all(t.data, "$input$", "{input}", context.temp_allocator)
	t.data, _ = strings.replace_all(t.data, "$filename$", "{filename}", context.temp_allocator)
	t.url = old(t.url)
	t.thumbnail_url = old(t.thumbnail_url)
	t.deletion_url = old(t.deletion_url)
	t.error_message = old(t.error_message)
}

// -1, 0 or 1 as version a is older, the same or newer than b ("13.7.1"; a missing part is 0).
version_compare :: proc(a, b: string) -> int {
	pa := strings.split(a, ".", context.temp_allocator)
	pb := strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< max(len(pa), len(pb)) {
		x, y := 0, 0
		if i < len(pa) { x = strconv.parse_int(strings.trim_space(pa[i]), 10) or_else 0 }
		if i < len(pb) { y = strconv.parse_int(strings.trim_space(pb[i]), 10) or_else 0 }
		if x != y { return x < y ? -1 : 1 }
	}
	return 0
}

// The host of a URL, without its scheme, port or path ("" when there is none).
@(private = "file")
url_host :: proc(url: string) -> string {
	rest := url
	if i := strings.index(rest, "://"); i >= 0 { rest = rest[i + 3:] }
	if i := strings.index_any(rest, "/?#"); i >= 0 { rest = rest[:i] }
	if i := strings.last_index_byte(rest, '@'); i >= 0 { rest = rest[i + 1:] }
	if i := strings.last_index_byte(rest, ':'); i >= 0 && !strings.has_suffix(rest, "]") { rest = rest[:i] }
	return rest
}

// The request

// A request ready to send (temp allocator; the body may be the file itself).
Upload_Request :: struct {
	method:  string,
	url:     string,
	headers: []http.Header,
	body:    []u8,
}

// The request that uploads `file` (named file_name) with `u`, its syntax expanded; or, with no file, the one that sends
// `input` (an address to shorten: {input}). problem: why it cannot be made (temp allocator; "": none).
uploader_request :: proc(u: Uploader, file: []u8, file_name: string, input := "") -> (r: Upload_Request, problem: string) {
	in_url := Syntax{file_name = file_name, input = input, url_encode = true}
	in_text := Syntax{file_name = file_name, input = input}
	r.method = u.method
	url, why := syntax_expand(u.request_url, in_url)
	if why != "" { return {}, why }
	url = strings.trim_space(url)
	if !strings.contains(url, "://") { url = strings.concatenate({"https://", url}, context.temp_allocator) }   // (ShareX's FixPrefix)
	params := make([]http.Param, len(u.parameters), context.temp_allocator)
	for p, i in u.parameters {
		value, bad := syntax_expand(p.value, in_text)
		if bad != "" { return {}, bad }
		params[i] = {p.name, value}
	}
	r.url = http.query_append(url, params, context.temp_allocator)

	headers := make([dynamic]http.Header, context.temp_allocator)
	for h in u.headers {
		value, bad := syntax_expand(h.value, in_text)
		if bad != "" { return {}, bad }
		append(&headers, http.Header{h.name, value})
	}
	_, has_type := http.header_value(headers[:], "Content-Type")
	content_type := ""
	if input != "" {
		// (a text sent, not a file: a URL shortener's request, whose body is any of ShareX's but a file's)
		#partial switch u.body {
		case .None:
		case .Multipart_Form_Data, .Form_Url_Encoded:
			fields := make([dynamic]http.Form_Field, context.temp_allocator)
			pairs := strings.builder_make(context.temp_allocator)
			for a in u.arguments {
				value, bad := syntax_expand(a.value, in_text)
				if bad != "" { return {}, bad }
				append(&fields, http.form_text(a.name, value))
				if strings.builder_len(pairs) > 0 { strings.write_byte(&pairs, '&') }
				strings.write_string(&pairs, http.form_encode(a.name, context.temp_allocator))
				strings.write_byte(&pairs, '=')
				strings.write_string(&pairs, http.form_encode(value, context.temp_allocator))
			}
			if u.body == .Multipart_Form_Data {
				r.body, content_type = http.multipart(fields[:], context.temp_allocator)
			} else {
				r.body, content_type = transmute([]u8)strings.to_string(pairs), "application/x-www-form-urlencoded"
			}
		case .Json, .Xml:
			data, bad := syntax_expand(u.data, in_text)
			if bad != "" { return {}, bad }
			r.body, content_type = transmute([]u8)data, u.body == .Json ? "application/json" : "application/xml"
		case:
			return {}, fmt.tprintf(i18n.tr("the uploader's body is %s: it sends a file, not an address"), UPLOADER_BODY_NAMES[u.body])
		}
		if content_type != "" && !has_type { append(&headers, http.Header{"Content-Type", content_type}) }
		r.headers = headers[:]
		return r, ""
	}
	#partial switch u.body {
	case .Multipart_Form_Data:
		if u.file_form_name == "" { return {}, i18n.tr("the uploader has no FileFormName: the form field of the file") }
		fields := make([dynamic]http.Form_Field, context.temp_allocator)
		for a in u.arguments {
			value, bad := syntax_expand(a.value, in_text)
			if bad != "" { return {}, bad }
			append(&fields, http.form_text(a.name, value))
		}
		append(&fields, http.form_file(u.file_form_name, file_name, mime_type(file_name), file))
		r.body, content_type = http.multipart(fields[:], context.temp_allocator)
	case .Binary:
		r.body, content_type = file, mime_type(file_name)
	case:
		return {}, fmt.tprintf(i18n.tr("the uploader's body is %s: cliche sends a file as MultipartFormData or Binary"), UPLOADER_BODY_NAMES[u.body])
	}
	if !has_type { append(&headers, http.Header{"Content-Type", content_type}) }
	r.headers = headers[:]
	return r, ""
}

// The type of a file by its extension: what a host needs to show it.
mime_type :: proc(file_name: string) -> string {
	dot := strings.last_index_byte(file_name, '.')
	ext := dot < 0 ? "" : ascii.lower(file_name[dot + 1:], context.temp_allocator)
	switch ext {
	case "png":         return "image/png"
	case "jpg", "jpeg": return "image/jpeg"
	case "gif":         return "image/gif"
	case "webp":        return "image/webp"
	case "mp4":         return "video/mp4"
	case "webm":        return "video/webm"
	case "txt":         return "text/plain"
	}
	return "application/octet-stream"
}

// The URL of the upload read from the host's answer (temp allocator). A status that is not 2xx is a problem: the
// uploader's ErrorMessage read from the answer when it has one, else the status and the start of the answer.
uploader_answer :: proc(u: Uploader, a: Answer, file_name: string) -> (url: string, problem: string) {
	answer := a
	s := Syntax{file_name = file_name, url_encode = true, answer = &answer}
	if a.status < 200 || a.status > 299 {
		if u.error_message != "" {
			if message, _ := syntax_expand(u.error_message, s); strings.trim_space(message) != "" {
				return "", fmt.tprintf(i18n.tr("%s answered: %s"), u.name, strings.trim_space(message))
			}
		}
		first := strings.trim_space(a.text)
		if i := strings.index_any(first, "\r\n"); i >= 0 { first = first[:i] }
		if len(first) > 120 { first = first[:120] }
		if first == "" { return "", fmt.tprintf(i18n.tr("%s answered with the status %d"), u.name, a.status) }
		return "", fmt.tprintf(i18n.tr("%s answered with the status %d: %s"), u.name, a.status, first)
	}
	if u.url == "" {
		url = strings.trim_space(a.text)
	} else {
		expanded, why := syntax_expand(u.url, s)
		if why != "" { return "", why }
		url = strings.trim_space(expanded)
	}
	if url == "" { return "", fmt.tprintf(i18n.tr("%s gave no URL in its answer"), u.name) }
	return url, ""
}

// The upload, on the worker: `file` (named file_name, a PNG file's bytes) sent with `u`, and the URL its host answered.
// It blocks for as long as the host takes (UPLOAD_TIMEOUT at most). url and problem are the allocator's ("": none).
upload_shot :: proc(u: Uploader, png: []u8, file_name: string, allocator := context.allocator) -> (url: string, problem: string) {
	r, why := uploader_request(u, png, file_name)
	if why != "" { return "", strings.clone(why, allocator) }
	req := http.Request{
		max_bytes = UPLOAD_ANSWER_MAX, user_agent = APP_NAME, timeout = UPLOAD_TIMEOUT,
		headers = r.headers, body = r.body,
	}
	res, err := http.request(r.method, r.url, req, context.temp_allocator)
	if err != .None { return "", fmt.aprintf("%s: %s", u.name, http.error_text(err), allocator = allocator) }
	link, failed := uploader_answer(u, {status = res.status, text = string(res.body), url = res.url, headers = res.headers}, file_name)
	if failed != "" { return "", strings.clone(failed, allocator) }
	return strings.clone(link, allocator), ""
}

// An address shortened by `u` (a URL shortener), on the worker: it blocks for as long as the service takes. short and
// problem are the allocator's ("": none).
shorten_url :: proc(u: Uploader, address: string, allocator := context.allocator) -> (short: string, problem: string) {
	r, why := uploader_request(u, nil, "", input = address)
	if why != "" { return "", strings.clone(why, allocator) }
	req := http.Request{
		max_bytes = UPLOAD_ANSWER_MAX, user_agent = APP_NAME, timeout = UPLOAD_TIMEOUT,
		headers = r.headers, body = r.body,
	}
	res, err := http.request(r.method, r.url, req, context.temp_allocator)
	if err != .None { return "", fmt.aprintf("%s: %s", u.name, http.error_text(err), allocator = allocator) }
	link, failed := uploader_answer(u, {status = res.status, text = string(res.body), url = res.url, headers = res.headers}, "")
	if failed != "" { return "", strings.clone(failed, allocator) }
	// (is.gd answers an error as text with a 200 on some failures: an answer that is no address is one)
	if !strings.has_prefix(link, "http://") && !strings.has_prefix(link, "https://") {
		return "", fmt.aprintf(i18n.tr("%s answered: %s"), u.name, link, allocator = allocator)
	}
	return strings.clone(link, allocator), ""
}

// Where the uploaders are kept

UPLOADER_EXTENSION :: ".sxcu"

// <config dir>/cliche/uploaders.
uploaders_folder :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({platform.user_dir(.Config, APP_NAME, context.temp_allocator), "/uploaders"}, allocator)
}

// The built-in uploader and shorteners, then those of the folder, sorted by file name. problems: one line per file that cannot be used
// ("name.sxcu: why"). All of it is the allocator's (uploaders_destroy, and each problem). It reads the disk: the worker
// calls it.
uploaders_load :: proc(allocator := context.allocator) -> (list: []Uploader, problems: []string) {
	out := make([dynamic]Uploader, allocator)
	bad := make([dynamic]string, allocator)
	builtin, _ := uploader_parse(transmute([]u8)string(BUILTIN_UPLOADER), "", allocator)
	append(&out, builtin)
	shorteners := BUILTIN_SHORTENERS
	for text in shorteners {
		s, _ := uploader_parse(transmute([]u8)string(text), "", allocator)
		append(&out, s)
	}
	folder := uploaders_folder()
	entries, err := os.read_directory_by_path(folder, 0, context.temp_allocator)
	if err == nil {
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
		for e in entries {
			if e.type == .Directory || !strings.has_suffix(ascii.lower(e.name, context.temp_allocator), UPLOADER_EXTENSION) { continue }
			path := strings.concatenate({folder, "/", e.name}, context.temp_allocator)
			data, read_err := os.read_entire_file(path, context.temp_allocator)
			if read_err != nil { append(&bad, fmt.aprintf(i18n.tr("%s: cannot be read"), e.name, allocator = allocator)); continue }
			u, problem := uploader_parse(data, path, allocator)
			if problem != "" { append(&bad, fmt.aprintf("%s: %s", e.name, problem, allocator = allocator)); continue }
			append(&out, u)
		}
	}
	return out[:], bad[:]
}

// The uploader named `name` in the list that uploads (or, `shortener`, that shortens addresses); the first built-in one
// of that use when none has that name (a file removed since, or "": the default).
uploader_find :: proc(list: []Uploader, name: string, shortener := false) -> (u: ^Uploader, found: bool) {
	fits :: proc(u: Uploader, shortener: bool) -> bool { return shortener ? uploader_shortens(u) : uploader_uploads(u) }
	for &x in list { if x.name == name && fits(x, shortener) { return &x, true } }
	for &x in list { if x.file == "" && fits(x, shortener) { return &x, false } }
	return nil, false
}

// A .sxcu file copied into the uploaders' folder, once it reads as an uploader, under the name ShareX would give it
// (<name>.sxcu; " (2)" when that file exists). name: the uploader's name (the allocator's). It reads and writes the disk:
// the worker calls it.
uploader_import :: proc(path: string, allocator := context.allocator) -> (name: string, problem: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", strings.clone(i18n.tr("the file cannot be read"), allocator) }
	u, why := uploader_parse(data, path, context.temp_allocator)
	if why != "" { return "", strings.clone(why, allocator) }
	folder := uploaders_folder()
	if os.make_directory_all(folder) != nil && !folder_exists(folder) { return "", strings.clone(i18n.tr("the uploaders' folder cannot be made"), allocator) }
	stem := file_name_safe(u.name)
	for n in 1 ..= NAME_TRIES {
		file := n == 1 ? strings.concatenate({stem, UPLOADER_EXTENSION}, context.temp_allocator) : fmt.tprintf("%s (%d)%s", stem, n, UPLOADER_EXTENSION)
		target := strings.concatenate({folder, "/", file}, context.temp_allocator)
		if os.exists(target) { continue }
		if !fsx.write_atomic(target, data) { return "", strings.clone(i18n.tr("the file cannot be written in the uploaders' folder"), allocator) }
		return strings.clone(u.name, allocator), ""
	}
	return "", strings.clone(i18n.tr("the uploaders' folder has too many files of that name"), allocator)
}

// A name as a file's: the characters that a system refuses in a file name become "_".
@(private = "file")
file_name_safe :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)name {
		switch c {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 ..< 32: strings.write_byte(&b, '_')
		case:                                                      strings.write_byte(&b, c)
		}
	}
	out := strings.trim(strings.to_string(b), " .")
	return out != "" ? out : "uploader"
}
