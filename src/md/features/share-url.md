# Share URL

A workflow's Share URL step sends an address to a ShareX URL sharing service: a `.sxcu` file whose `DestinationType`
holds `URLSharingService`. It mirrors the Shorten URL step: an address in, an action "when", the address out and
"done".

## The same request, nothing read back

ShareX's custom URL sharer sends the request with the address as `{input}`, as a shortener does, and expects no address
in the answer. So `share_url` builds the request with `uploader_request(input = ...)` and checks only that the service
took it: a 2xx status. A refusal is said as an upload's is (`uploader_refused`: the uploader's `ErrorMessage` read from
the answer, else the status and the first line).

The step passes the same address on: a Copy text or an Open after it still has one.

## Which service

An uploader serves one or more uses (`Uploader_Use`: Upload, Shorten, Share), read from its destinations. No sharing
service is built in: an empty choice takes the first one of the uploaders' folder, and with none the step fails and
says to add one. An imported sharing service does not become the default host (`upload.uploader`): only a host does.

## What the run says

The notification of a run that shared says "Address shared" with the address. A refused share after an upload says
"Uploaded, not shared" and why: the address is kept in the history by the step that keeps it, and the reason is the
news.
