package cliche

import "core:strings"
import "core:testing"
import http "gt:http"

// catbox.moe's own file (https://catbox.moe/resources/catbox.moe.sxcu): no Name, a null argument.
@(private = "file")
CATBOX_SXCU :: `{
  "Version": "18.0.2",
  "DestinationType": "ImageUploader, TextUploader, FileUploader",
  "RequestMethod": "POST",
  "RequestURL": "https://catbox.moe/user/api.php",
  "Body": "MultipartFormData",
  "Arguments": {
    "userhash": null,
    "reqtype": "fileupload"
  },
  "FileFormName": "fileToUpload"
}`

// A host that answers JSON, as ShareX's documentation shows one: parameters, a header, the file's name in the address.
@(private = "file")
JSON_SXCU :: `{
  "Version": "16.1.0",
  "Name": "Example",
  "DestinationType": "ImageUploader",
  "RequestMethod": "post",
  "RequestURL": "example.com/api/upload/{filename}",
  "Parameters": {
    "private": "true"
  },
  "Headers": {
    "Authorization": "Basic {base64:user:pw}"
  },
  "Body": "MultipartFormData",
  "Arguments": {
    "title": "{filename}"
  },
  "FileFormName": "file",
  "URL": "{json:files[0].url}",
  "ThumbnailURL": "{json:files[0].thumb}",
  "DeletionURL": "https://example.com/delete/{json:$.files[0].id}",
  "ErrorMessage": "{json:error.message}"
}`

// A PUT of the file itself, with a type of its own.
@(private = "file")
BINARY_SXCU :: `{
  "Version": "15.0.0",
  "Name": "Bucket",
  "RequestMethod": "PUT",
  "RequestURL": "https://bucket.example.com/shots/{filename}",
  "Headers": { "Content-Type": "application/x-shot", "X-Key": "k" },
  "Body": "Binary",
  "URL": "{responseurl}"
}`

@(test)
uploader_parse_files :: proc(t: ^testing.T) {
	u, problem := uploader_parse(transmute([]u8)string(CATBOX_SXCU), "/x/catbox.moe.sxcu", context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, u.name, "catbox.moe")   // (no Name: the host, as ShareX shows it)
	testing.expect_value(t, u.file, "/x/catbox.moe.sxcu")
	testing.expect_value(t, u.method, "POST")
	testing.expect_value(t, u.body, Uploader_Body.Multipart_Form_Data)
	testing.expect_value(t, u.destinations, Destinations{.Image_Uploader, .Text_Uploader, .File_Uploader})
	testing.expect_value(t, u.file_form_name, "fileToUpload")
	testing.expect_value(t, len(u.arguments), 2)
	testing.expect_value(t, u.arguments[0], http.Param{"reqtype", "fileupload"})   // (sorted by name)
	testing.expect_value(t, u.arguments[1], http.Param{"userhash", ""})            // (null: empty)
	testing.expect_value(t, u.url, "")

	u, problem = uploader_parse(transmute([]u8)string(JSON_SXCU), "", context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, u.name, "Example")
	testing.expect_value(t, u.method, "POST")
	testing.expect_value(t, len(u.parameters), 1)
	testing.expect_value(t, u.headers[0], http.Header{"Authorization", "Basic {base64:user:pw}"})
	testing.expect_value(t, u.url, "{json:files[0].url}")
	testing.expect_value(t, u.error_message, "{json:error.message}")

	u, problem = uploader_parse(transmute([]u8)string(BINARY_SXCU), "", context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, u.method, "PUT")
	testing.expect_value(t, u.body, Uploader_Body.Binary)
	testing.expect_value(t, u.destinations, Destinations{})

	builtin, builtin_problem := uploader_parse(transmute([]u8)string(BUILTIN_UPLOADER), "", context.temp_allocator)
	testing.expect_value(t, builtin_problem, "")
	testing.expect_value(t, builtin.name, BUILTIN_UPLOADER_NAME)
	testing.expect_value(t, builtin.arguments[1], http.Param{"time", "72h"})
}

@(test)
uploader_parse_refuses :: proc(t: ^testing.T) {
	parse_problem :: proc(text: string) -> string {
		_, problem := uploader_parse(transmute([]u8)text, "", context.temp_allocator)
		return problem
	}
	testing.expect(t, parse_problem("not json {") != "")
	testing.expect(t, parse_problem("[1, 2]") != "")
	testing.expect(t, parse_problem(`{"Version": "15.0.0"}`) != "", "no RequestURL")
	testing.expect(t, parse_problem(`{"RequestURL": "https://h/"}`) != "", "no Version: ShareX refuses it too")
	testing.expect(t, parse_problem(`{"Version": "12.3.1", "RequestURL": "https://h/"}`) != "", "the old format")
	testing.expect(t, parse_problem(`{"Version": "15.0.0", "RequestURL": "https://h/", "Body": "Pigeon"}`) != "")
	testing.expect(t, parse_problem(`{"Version": "15.0.0", "RequestURL": "https://h/", "RequestMethod": "BREW"}`) != "")
	testing.expect_value(t, parse_problem(`{"Version": "15.0.0", "RequestURL": "https://h/", "RequestMethod": 2, "Body": 5}`), "")
}

// Up to 13.7.1 the syntax was $name$: it reads as {name}, and a brace that was a character stays one.
@(test)
uploader_old_syntax :: proc(t: ^testing.T) {
	text := `{"Version": "13.5.0", "RequestURL": "https://h/up", "Body": "Binary", "URL": "https://h/$json:id$#{x}"}`
	u, problem := uploader_parse(transmute([]u8)text, "", context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, u.url, "https://h/{json:id}#\\{x\\}")
	link, link_problem := uploader_answer(u, {status = 200, text = `{"id": "abc"}`}, "a.png")
	testing.expect_value(t, link_problem, "")
	testing.expect_value(t, link, "https://h/abc#{x}")
}

@(test)
syntax_of_the_request :: proc(t: ^testing.T) {
	s := Syntax{file_name = "my shot.png"}
	expand_text :: proc(text: string, s: Syntax) -> string {
		out, _ := syntax_expand(text, s)
		return out
	}
	testing.expect_value(t, expand_text("plain", s), "plain")
	testing.expect_value(t, expand_text("name: {filename}", s), "name: my shot.png")
	testing.expect_value(t, expand_text("{FileName}", {file_name = "my shot.png", url_encode = true}), "my%20shot.png")
	testing.expect_value(t, expand_text("Basic {base64:user:pw}", s), "Basic dXNlcjpwdw==")
	testing.expect_value(t, expand_text("{random:only}", s), "only")
	picked := expand_text("{random:a|b}", s)
	testing.expect(t, picked == "a" || picked == "b")
	testing.expect_value(t, expand_text("{select:first|second}", s), "first")
	testing.expect_value(t, expand_text("{inputbox:Title|default}", s), "default")
	testing.expect_value(t, expand_text("[{input}]", s), "[]")
	testing.expect_value(t, expand_text(`\{not a call\} a\|b \\`, s), `{not a call} a|b \`)
	testing.expect_value(t, expand_text("a|b", s), "a")   // (ShareX's parse: an unescaped | ends the text)

	_, problem := syntax_expand("https://h/{response}", s)
	testing.expect(t, problem != "", "no answer yet")
	_, problem = syntax_expand("{nothing}", s)
	testing.expect(t, problem != "", "an unknown name")
}

@(test)
syntax_of_the_answer :: proc(t: ^testing.T) {
	answer := Answer{
		status  = 200,
		text    = `{"files": [{"url": "https:\/\/example.com\/a.png", "id": 7, "thumb": null}], "ok": true, "error": {}}`,
		url     = "https://example.com/upload/final",
		headers = {{"Content-Type", "application/json"}, {"Location", "https://example.com/l/1"}},
	}
	s := Syntax{file_name = "a b.png", url_encode = true, answer = &answer}
	expect_text :: proc(t: ^testing.T, text: string, s: Syntax, expected: string, loc := #caller_location) {
		out, problem := syntax_expand(text, s)
		testing.expect_value(t, problem, "", loc = loc)
		testing.expect_value(t, out, expected, loc = loc)
	}
	expect_text(t, "{json:files[0].url}", s, "https://example.com/a.png")
	expect_text(t, "{json:$.files[0].id}", s, "7")
	expect_text(t, "{json:files[-1]['url']}", s, "https://example.com/a.png")
	expect_text(t, "{json:ok}", s, "True")
	expect_text(t, "{json:files[0].thumb}", s, "")
	expect_text(t, "{json:missing.path}", s, "")
	expect_text(t, "{json:files[3].url}", s, "")
	expect_text(t, "{json:{response}|ok}", s, "True")   // (the input of a call is a call)
	expect_text(t, "{header:location}", s, "https://example.com/l/1")
	expect_text(t, "{header:X-None}", s, "")
	expect_text(t, "{responseurl}", s, "https://example.com/upload/final")
	expect_text(t, "https://example.com/{filename}", s, "https://example.com/a%20b.png")
	_, problem := syntax_expand("{json:files}", s)
	testing.expect(t, problem != "", "a list is not a text")

	text_answer := Answer{status = 200, text = "abc123\n"}
	s.answer = &text_answer
	expect_text(t, "https://h/{response}", s, "https://h/abc123\n")
	expect_text(t, "{regex:[a-z]+}", s, "abc")
	expect_text(t, "{regex:[a-z]+(\\\\d+)|1}", s, "123")   // (`\\d` in the file: a backslash before d)
	expect_text(t, "{regex:(?<letters>[a-z]+)(?<digits>\\\\d+)|digits}", s, "123")
	expect_text(t, "{regex:x(\\\\d)|1}", s, "")
	expect_text(t, "{regex:say hi 42|(\\\\d+)|1}", s, "42")
	_, problem = syntax_expand("{json:<html>|a}", s)
	testing.expect(t, problem != "", "not JSON")
	_, problem = syntax_expand("{regex:(\\\\d+)|name}", s)
	testing.expect(t, problem != "", "no such group")

	xml_answer := Answer{
		status = 200,
		text   = `<?xml version="1.0" encoding="UTF-8"?><files><file><name>a.png</name><url>https://x/a.png?a=1&amp;b=2</url></file><file id="2"><url>https://x/b.png</url></file></files>`,
	}
	s.answer = &xml_answer
	expect_text(t, "{xml:/files/file[1]/url}", s, "https://x/a.png?a=1&b=2")
	expect_text(t, "{xml:/files/file[2]/url}", s, "https://x/b.png")
	expect_text(t, "{xml://url}", s, "https://x/a.png?a=1&b=2")
	expect_text(t, "{xml:/files/file[2]/@id}", s, "2")
	expect_text(t, "{xml:/files/*[1]/name/text()}", s, "a.png")
	expect_text(t, "{xml:/files/file[3]/url}", s, "")
}

@(test)
uploader_answers :: proc(t: ^testing.T) {
	catbox, _ := uploader_parse(transmute([]u8)string(CATBOX_SXCU), "", context.temp_allocator)
	link, problem := uploader_answer(catbox, {status = 200, text = "https://files.catbox.moe/abc.png\n"}, "a.png")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, link, "https://files.catbox.moe/abc.png")   // (no URL: the answer, trimmed)
	link, problem = uploader_answer(catbox, {status = 200, text = "  "}, "a.png")
	testing.expect(t, problem != "", "an empty answer has no URL")
	link, problem = uploader_answer(catbox, {status = 412, text = "File too big.\nmore"}, "a.png")
	testing.expect_value(t, problem, "catbox.moe answered with the status 412: File too big.")

	example, _ := uploader_parse(transmute([]u8)string(JSON_SXCU), "", context.temp_allocator)
	link, problem = uploader_answer(example, {status = 201, text = `{"files": [{"url": "https://e.com/x.png"}]}`}, "a.png")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, link, "https://e.com/x.png")
	link, problem = uploader_answer(example, {status = 403, text = `{"error": {"message": "bad key"}}`}, "a.png")
	testing.expect_value(t, problem, "Example answered: bad key")
	link, problem = uploader_answer(example, {status = 500, text = ""}, "a.png")
	testing.expect_value(t, problem, "Example answered with the status 500")
}

// The request of an uploader: its address with the query, its headers, the multipart body byte for byte.
@(test)
uploader_requests :: proc(t: ^testing.T) {
	png := transmute([]u8)string("\x89PNG")
	example, _ := uploader_parse(transmute([]u8)string(JSON_SXCU), "", context.temp_allocator)
	r, problem := uploader_request(example, png, "shot 1.png")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, r.method, "POST")
	testing.expect_value(t, r.url, "https://example.com/api/upload/shot%201.png?private=true")
	testing.expect_value(t, len(r.headers), 2)
	testing.expect_value(t, r.headers[0], http.Header{"Authorization", "Basic dXNlcjpwdw=="})
	testing.expect_value(t, r.headers[1].name, "Content-Type")
	PREFIX :: "multipart/form-data; boundary="
	testing.expect(t, strings.has_prefix(r.headers[1].value, PREFIX))
	boundary := r.headers[1].value[len(PREFIX):]
	expected := strings.concatenate({
		"--", boundary, "\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nshot 1.png\r\n",
		"--", boundary, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"shot 1.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n",
		"--", boundary, "--\r\n",
	}, context.temp_allocator)
	testing.expect_value(t, string(r.body), expected)

	bucket, _ := uploader_parse(transmute([]u8)string(BINARY_SXCU), "", context.temp_allocator)
	r, problem = uploader_request(bucket, png, "a.png")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, r.method, "PUT")
	testing.expect_value(t, r.url, "https://bucket.example.com/shots/a.png")
	testing.expect_value(t, string(r.body), "\x89PNG")
	testing.expect_value(t, len(r.headers), 2)   // (its own Content-Type: none added)
	content_type, _ := http.header_value(r.headers, "content-type")
	testing.expect_value(t, content_type, "application/x-shot")

	form_text := `{"Version": "15.0.0", "RequestURL": "https://h/", "Body": "FormURLEncoded"}`
	form, _ := uploader_parse(transmute([]u8)form_text, "", context.temp_allocator)
	_, problem = uploader_request(form, png, "a.png")
	testing.expect(t, problem != "", "a form without a file cannot carry the picture")

	no_field := `{"Version": "15.0.0", "RequestURL": "https://h/", "Body": "MultipartFormData"}`
	nameless, _ := uploader_parse(transmute([]u8)no_field, "", context.temp_allocator)
	_, problem = uploader_request(nameless, png, "a.png")
	testing.expect(t, problem != "", "no FileFormName")
}

@(test)
uploader_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, version_compare("13.7.1", "13.7.1"), 0)
	testing.expect_value(t, version_compare("13.7", "13.7.1"), -1)
	testing.expect_value(t, version_compare("14.0.0", "13.7.1"), 1)
	testing.expect_value(t, version_compare("12.10", "12.4"), 1)
	testing.expect_value(t, mime_type("A.PNG"), "image/png")
	testing.expect_value(t, mime_type("noext"), "application/octet-stream")
	testing.expect_value(t, url_encode("a b/é~"), "a%20b%2F%C3%A9~")
	list := []Uploader{{name = "builtin"}, {name = "mine", file = "/f/mine.sxcu"}}
	u, found := uploader_find(list, "mine")
	testing.expect(t, found && u.name == "mine")
	u, found = uploader_find(list, "gone")
	testing.expect(t, !found && u.name == "builtin", "the built-in one when the chosen is gone")
}

// A URL shortener: the built-in ones read, its request carries the address ({input}), the lists keep the uses apart.
@(test)
uploader_shortens_addresses :: proc(t: ^testing.T) {
	shorteners := BUILTIN_SHORTENERS
	isgd, problem := uploader_parse(transmute([]u8)string(shorteners[0]), "", context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, isgd.name, BUILTIN_SHORTENER_NAME)
	testing.expect(t, uploader_shortens(isgd) && !uploader_uploads(isgd), "is.gd shortens and uploads nothing")
	r, why := uploader_request(isgd, nil, "", input = "https://e.com/a b?x=1")
	testing.expect_value(t, why, "")
	testing.expect_value(t, r.method, "GET")
	testing.expect_value(t, r.url, "https://is.gd/create.php?format=simple&url=https%3A%2F%2Fe.com%2Fa+b%3Fx%3D1")
	testing.expect_value(t, len(r.body), 0)

	// (a ShareX shortener that posts a form)
	form_text := `{"Version": "15.0.0", "Name": "S", "DestinationType": "URLShortener", "RequestURL": "https://s/", "Body": "FormURLEncoded", "Arguments": {"url": "{input}"}}`
	form, _ := uploader_parse(transmute([]u8)form_text, "", context.temp_allocator)
	r, why = uploader_request(form, nil, "", input = "https://e.com/?q=a&b")
	testing.expect_value(t, why, "")
	testing.expect_value(t, string(r.body), "url=https%3A%2F%2Fe.com%2F%3Fq%3Da%26b")
	content_type, _ := http.header_value(r.headers, "Content-Type")
	testing.expect_value(t, content_type, "application/x-www-form-urlencoded")

	litterbox, _ := uploader_parse(transmute([]u8)string(BUILTIN_UPLOADER), "", context.temp_allocator)
	list := []Uploader{litterbox, isgd, {name = "mine", file = "/f/mine.sxcu", destinations = {.Url_Shortener}}}
	testing.expect_value(t, len(uploaders_names(list, shorteners = false, allocator = context.temp_allocator)), 1)
	names := uploaders_names(list, shorteners = true, allocator = context.temp_allocator)
	testing.expect(t, len(names) == 2 && names[0] == BUILTIN_SHORTENER_NAME && names[1] == "mine", "the shorteners, in order")
	u, found := uploader_find(list, "", shortener = true)
	testing.expect(t, !found && u.name == BUILTIN_SHORTENER_NAME, "the built-in shortener by default")
	u, found = uploader_find(list, "mine")
	testing.expect(t, !found && u.name == litterbox.name, "a shortener is no host for a picture")
}
