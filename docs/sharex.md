# cliche vs ShareX: features and ergonomics

Scope: ShareX 15/16 (image editor, region capture, capture menu, after-capture and after-upload tasks, tools menu,
history, hotkeys). File references are to `/home/sacha/Projects/cliche/src`. Where a ShareX detail is not certain, the
cell says "(check)".

Priority: P1 = an everyday feature whose lack annoys; P2 = often useful; P3 = rare.
Effort: S = under a day; M = a few days; L = a week or more.

## 1. Feature table

### 1.1 Capture

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Region capture on a frozen screen | `overlay.odin:12-19`, trigger `.Region` `workflow.odin:20` | none | – | – |
| Click a window or a control in region mode | window only: `frame_pick` `overlay.odin:223` (setting `region.frame_windows`) | partial: no child controls (Windows only in ShareX) | P3 | M; Windows only, `grab.odin` |
| Region: move and resize the rectangle with handles after drawing | keys only (arrows, Shift+arrows) `overlay.odin:241-256` | partial: no mouse handles, a click inside confirms | P1 | S; reuse `Edit_Handle` logic of `editor_model.odin:134` in `geometry.odin` `Selection` |
| Region spans several monitors | one output per overlay `overlay.odin:7-10` | missing | P2 | L; one layer surface per output, one shared `Selection` in desktop coordinates |
| Magnifier, crosshair, size/position info in region mode | magnifier `overlay.odin:354`, label `overlay.odin:306` | partial: no full-screen crosshair lines | P3 | S; draw two lines in `overlay_draw` |
| Annotate inside the region overlay before confirm | trigger `.Edit` opens the editor after the region (`workflow.odin:33`) | partial: two steps instead of one | P3 | – ; the editor is enough if it opens fast |
| Last region | no | missing | P1 | S; keep the last `o.chosen` in `App`; new trigger `.Last_Region` in `workflow.odin:20` |
| Custom / fixed-size region | no | missing | P3 | S; trigger parameter (x, y, w, h) |
| Fullscreen (all monitors) | `.Screen` = output under the pointer `grab.odin:21` | partial: no "all outputs" | P2 | S; a `Source.All_Screens`, worker grabs the whole desktop (already done for Region) |
| Monitor (choose one) | output under the pointer | partial: no menu of monitors | P3 | S; tray submenu |
| Active window | trigger `.Window` | none | – | – |
| Window from a list | no | missing | P3 | M; needs window list (`app.desktop.windows`) in a menu |
| Screenshot delay | `capture.delay` `settings.odin:28`; not for Region `app.odin:399` | partial: one global value, no per-workflow delay, no countdown shown | P2 | S; a `delay` parameter on the Capture node `workflow_nodes.odin:74` |
| Show cursor in screenshot | recordings only `settings.odin:36` | missing for pictures | P2 | M; gt:capture must give the cursor image and position |
| Scrolling capture | no | decided: not now (WP5, "Decisions") | P2 | L; scroll events + frame stitching in gt:capture/gt:image, Windows first (Wayland cannot inject scroll without portals) |
| Auto capture (every N seconds) | no | decided: not now (WP5, "Decisions") | P3 | S; timer in `app.odin` that fires a trigger |
| Text capture (OCR) | trigger `.Ocr`, node Read text `workflow_nodes.odin:183`, `ocr_read.odin` | none | – | – |
| Screen recording MP4 | `record.odin`, `Record_Format.Mp4` `record.odin:33` | partial: no audio, no pause | P2 | L for audio; S for pause |
| Screen recording GIF | `Record_Format.Gif`, `record.gif_fps`, `record.gif_width` | none | – | – |
| Recording: region, screen, window | region chosen on the frozen screen `record.odin:9` | none | – | – |
| Recording: countdown before start | Record button on the record overlay `record_overlay.odin:1-10` | none (a manual start is better) | – | – |

### 1.2 Editor tools

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Select and move | `Edit_Tool.Select` `editor_model.odin:29`, key V | none | – | – |
| Rectangle | `.Rectangle`, key R, corners `Edit_Style.radius` | done (WP4) | – | – |
| Ellipse | `.Ellipse`, key E | none | – | – |
| Line | `.Line`, key L, `Edit_Style.dash` | done (WP4) | – | – |
| Arrow | `.Arrow`, key A, `Edit_Style.heads` (end, start, both) | done (WP4), no curved arrow | P3 | S |
| Freehand | `.Pen`, key P, scale handle | partial: no smoothing | P3 | S |
| Freehand arrow | `.Pen` with a head (`Edit_Style.heads`) | done (WP4) | – | – |
| Text (outline) | `.Text`, key T, plain colour `editor_export.odin` `.Text` case | partial: no outline, single line (`ui.line_edit` `editor.odin:837`), one font, no bold | P1 | M; `Edit_Style.text_look` (plain / outline / background), multi-line field (toolkit `ui.text_edit` if present, else Shift+Enter in `Line_Edit`) |
| Text (background) | no | missing | P1 | S once the item above lands; rounded box behind the text, colour = fill colour |
| Speech balloon | `Edit_Kind.Balloon`, key Q, tail handle | done (WP4) | – | – |
| Step number | `.Step`, key N, auto-increment `edit_step_next` `editor_model.odin:336` | partial: no start number, no letters / Roman, no tail to point | P2 | S; `Edit_Style.step_format`, a start value on the model |
| Magnifier | `Edit_Kind.Magnify`, key M, zoom 1.5 to 4, circle or rectangle | done (WP4) | – | – |
| Image from a file | Insert menu, Ctrl+I | done (WP4) | – | – |
| Image from the screen | Insert menu, Ctrl+Shift+I: the history's last screenshot | done (WP4), decided: no new capture | – | – |
| Sticker / emoji | Insert menu, `Edit_Kind.Sticker` (18 emoji from the font) | done (WP4) | – | – |
| Cursor | Insert menu, `Edit_Kind.Cursor` (a vector pointer) | done (WP4) | – | – |
| Smart eraser | `Edit_Kind.Eraser`, key X: the mean colour of its box's edge | done (WP4) | – | – |
| Blur | no (the Pixelate tool's tags say "blur" `editor.odin:78`) | missing | P1 | M; a blurred copy made on the chores like `edit_mosaic_make` `editor_export.odin:45`, drawn clipped; radius option |
| Pixelate | `.Pixelate`, key B, cell fixed `EDIT_PIXELATE_CELL` `editor_export.odin:21` | partial: no cell size option | P3 | S; option, mosaic recomputed per size |
| Highlighter | `.Highlighter`, key H, alpha 0.4 `editor_model.odin:77` | none (ShareX: rectangle highlight) | – | – |
| Crop | `.Crop`, key C, handles with the Crop tool | done (WP4); the crop applies at Done (no Enter-to-apply: Enter is Done) | – | – |
| Cut out (remove a horizontal or vertical band) | `.Cut_Out`, key K (`Edit_Op.Cut`) | done (WP4) | – | – |

### 1.3 Tool options

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Border (stroke) colour | 8 swatches `editor_model.odin:69`, bar `editor.odin:885` | partial: no custom colour, no recent colours, no eyedropper | P1 | S; toolkit colour picker (the workflow inspector has a `.Color` param type) in a popover after the swatches |
| Fill colour (separate) | `fill: bool` uses the stroke colour `editor_model.odin:64` | partial: fill = stroke colour only | P1 | S; `Edit_Style.fill_color` (0 alpha = none) |
| Thickness | 1–40 slider + field `editor.odin:895` | none | – | – |
| Line style (solid, dashed, dotted) | `Edit_Style.dash`, `draw.path_dash` | done (WP4) | – | – |
| Rounded corners | `Edit_Style.radius` | done (WP4) | – | – |
| Shadow | softness slider `editor.odin:907` | none (cliche has a softness; ShareX on/off) | – | – |
| Text font, size, bold, italic, alignment | 4 sizes S/M/L/XL `editor_model.odin:72` | partial: no font, no bold/italic, no free size | P2 | S for bold/size field; M for font choice |
| Opacity per shape | no | missing | P3 | S; alpha in `Edit_Style.color` |
| Arrow heads (start, end, both) | `Edit_Style.heads` | done (WP4) | – | – |
| Step: start number, type | auto only | partial | P2 | S |
| Blur radius / pixel size / magnify zoom | `Edit_Style.blur_radius`, `pixel_size` (WP1), `zoom` (WP4) | done | – | – |
| Options remembered per tool | `editor_choices_keep` `editor.odin:1063` | none | – | – |

### 1.4 Editor actions

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Undo / redo | Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y `editor.odin:81-82` | none | – | – |
| Delete, delete all | Delete `editor.odin:83` | partial: no delete all | P3 | S |
| Duplicate | Ctrl+D `editor.odin:84` | none | – | – |
| Copy / paste shapes, paste an image (Ctrl+V) | no | missing | P1 | M; paste image = `Edit_Kind.Image`; paste text = a Text shape |
| Bring to front / back, up / down | no | missing | P2 | S; reorder `doc.shapes` |
| Multi-select (box select, Shift+click) | `Edit_Shape.picked`; box select, Shift+click, Ctrl+A | done (WP4) | – | – |
| Zoom: percent shown + menu (fit, 100 %, 200 %…) | Ctrl+=, Ctrl+-, Ctrl+0 fit, Ctrl+wheel `editor.odin:86-88` | partial: no percent shown, no 100 % key, no menu | P1 | S; a button in the bar showing `view.zoom`, a `ui.menu` of steps, Ctrl+1 = 100 % |
| Confirm / cancel | Done (Enter) / Cancel (Ctrl+W, Escape) `editor.odin:869-873` | none | – | – |
| Copy | Ctrl+C `editor.odin:89` | none | – | – |
| Save | Ctrl+S to the default folder `editor.odin:725` | none | – | – |
| Save as (choose a folder, a name, a format) | no | missing | P1 | S; native save dialog (check gt:platform), then `Job_Save` with a path and a `Save_Format` |
| Upload | only through Done → the workflow | partial: no direct button | P1 | S; Ctrl+U sends a `Job_Node` Upload with the default uploader, result copies the URL |
| Pin to screen | no | missing | P2 | M; a borderless always-on-top window (gt:host overlay window) showing the picture; drag to move, wheel to zoom/opacity, Escape closes |
| Print | no | missing | P3 | M; Windows print dialog; Linux through the portal `org.freedesktop.portal.Print` |
| Resize image / resize canvas | Picture menu: a dialog each (`Edit_Op.Resize`, `Edit_Op.Canvas`) | done (WP4) | – | – |
| Rotate / flip | Picture menu, Ctrl+R, Ctrl+Shift+R (`Edit_Op.Rotate`, `Edit_Op.Flip`) | done (WP4) | – | – |
| Auto crop (trim uniform borders) | Picture menu, Ctrl+Shift+X (`image.trim_bounds`) | done (WP4) | – | – |
| Background / beautify | node Background `workflow_nodes.odin:114` | partial: not previewed in the editor | P2 | M; editor button that runs the node's op on a preview |
| Image effects | 14 nodes `workflow_nodes.odin:18-24` | partial: not in the editor | P3 | M |
| Open an image file in the editor | `editor_open_file` PNG only `editor.odin:258` | partial: no JPEG / WebP / BMP, no drag-and-drop onto the editor | P2 | S; decode with gt:image if it reads them; file-drop events from gt:platform (check) |

### 1.5 After-capture and after-upload actions

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Open in image editor | node Annotate `workflow_nodes.odin:159` | none | – | – |
| Copy image | node Copy image `:171` | none | – | – |
| Save to file, format, quality | node Save file, PNG/JPEG/WebP `:172`, `:55` | partial: no "save as" dialog step, no BMP/TIFF (rare) | P3 | S; a `Choice` "ask" on Save file |
| Save thumbnail | no | missing | P3 | S; Resize node + Save file already make it in a graph |
| Add image effects, watermark, border, shadow | nodes `:18-24`, Watermark `:123` | none (image watermark missing: P3) | P3 | S |
| Copy file path | Copy text accepts a file `:181`, `:68` | none | – | – |
| Copy file to clipboard (as a file) | no | missing | P3 | M; clipboard file list (text/uri-list) in gt:platform |
| Show file in folder | node Show in folder `:190` | none | – | – |
| Scan QR code | node Read QR `:182` | none | – | – |
| Recognize text | node Read text `:183` | none | – | – |
| Upload image | node Upload `:178`, `.sxcu` + Litterbox `uploader.odin:3-6,82` | partial: no OAuth hosts (Imgur account, Google Drive, S3 with signing…) | P2 | L per host; `.sxcu` covers most; S3/Imgur-anonymous as built-in `.sxcu` |
| Before-upload confirmation | node Ask: a notification with Yes and No, its "yes" and "no" action outputs (`workflow_app.odin` `workflow_ask`, `Questions` in `workflow_run.odin`) | done (WP5) | – | – |
| Delete file locally after upload | node Delete file; Upload's "done" action output to wait for the upload | done (WP5) | – | – |
| Shorten URL | node Shorten URL: is.gd, v.gd built in, or a `.sxcu` URL shortener (`{input}`), `uploader.odin` `shorten_url` | done (WP5) | – | – |
| Share URL (services) | no | decided: not now; a `URLSharingService` `.sxcu` is read, and the Shorten URL request (`uploader_request` with `input`) would send it | P3 | S |
| Copy URL | Copy text | none | – | – |
| Open URL in the browser | node Open (an address in the browser, a file with its program) | done (WP5) | – | – |
| Show QR code of the URL | node Make QR code (`gt:qr` encodes): text in, picture out | done (WP5) | – | – |
| Notification with thumbnail, click to open | a click on a run's notification opens its address, else its file (`Run_Summary.open`); no thumbnail | done (WP5), thumbnail not done | P3 | S; `Notification.icon_png` from the run's picture, encoded on the worker |
| Add to history | node `:191` | none | – | – |
| Conditions, branches | node Condition `:164` | cliche has more than ShareX | – | – |

### 1.6 Tools menu

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Screen colour picker (copies hex) | no | missing | P1 | S; new trigger `.Color`: the overlay with the magnifier, a click copies `#rrggbb` (pixel from the frozen frame) |
| Ruler | size label `overlay.odin:306` | decided: not now (WP5, "Decisions") | P3 | S; overlay mode that does not confirm |
| OCR | trigger `.Ocr` | none | – | – |
| QR code: decode | trigger `.Qr` | none | – | – |
| QR code: generate from text | node Make QR code; on the clipboard's text: a workflow of the Clipboard trigger | done (WP5) | – | – |
| Pin to screen | `pin.odin` (WP2); node Pin to the screen | done | – | – |
| Image combiner | history, two pictures or more selected: Combine side by side, Combine stacked (`gt:image` `combine`, `Job_Combine`) | done (WP5) | – | – |
| Image splitter, thumbnailer | no | missing | P3 | S |
| Image beautifier | node Background `:114` | none in a workflow; not a stand-alone tool | P3 | S |
| Video converter, video thumbnailer | no | missing | P3 | L |
| Hash checker | no | missing | P3 | S; not related to screenshots |
| Directory indexer, DNS changer, monitor test, clipboard viewer, inspect window, border-less window | no | missing | P3 | out of scope |

### 1.7 Upload sources

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Upload a file (any type) | trigger Upload_File (`cliche --upload-file`, the tray): the system's dialog; the Upload node takes a picture, a file or a text | done (WP5) | – | – |
| Upload from the clipboard (image, text, files) | trigger Clipboard (`cliche --upload-clipboard`, the tray): a picture, else files, else a text, on the Capture node's output of its kind | done (WP5) | – | – |
| Drag and drop to upload | no | missing | P3 | M; drop target on the main window |
| Upload from URL, watch folder | no | missing | P3 | M |

### 1.8 History

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| History list and image history with thumbnails | grid and list `history_view.odin:1-20` | none | – | – |
| Search, filter by type | `history_view.odin:1-5` | none | – | – |
| Open, show in folder, copy image / path / URL, edit, upload again, delete file, remove | `History_Action` `history_view.odin:157` | none | – | – |
| Filter by date, host | the calendar button: today, the last 7 days, the last 30 days (`history_period_start`); a host's name is found by the search (it is in the URL) | done (WP5) | – | – |
| Open URL of an entry | action Open the URL (Shift+Enter) | done (WP5) | – | – |
| Recent tasks in the tray menu | the tray's Recent submenu: the last 5 entries; a click opens the address, else the file | done (WP5) | – | – |

### 1.9 Settings and hotkeys

| ShareX | cliche today | Gap | Prio | Effort, fit |
|---|---|---|---|---|
| Any number of hotkeys, each with its own tasks | 7 fixed shortcuts `shortcuts.odin:19`; 6 fixed triggers, each runs one workflow `workflow.odin:20` | partial: no shortcut for `.Edit` "Capture a region and edit"; a workflow cannot have its own key | P1 | M; a shortcut belongs to a workflow: `shortcut` param on the Capture node, plus the trigger's source; `SHORTCUT_IDS` built from the workflows |
| Tray click actions | `general.tray_click` `settings.odin:25` | none | – | – |
| File name pattern | `save.name`, `pattern.odin` | partial: no counter `%i`, no window title, no random | P2 | S; fields in `pattern.odin` |
| Default folder | `save.folder` | none | – | – |
| Image format, JPEG quality | Save file node `:175-176` | none | – | – |
| Region options (confirm on release, window frames, magnifier, dim) | `settings.odin:52-55` | none | – | – |

## 2. Ergonomics

| ShareX | cliche today | Proposal |
|---|---|---|
| One key per tool, shown in the tooltip (R, E, L, A, F, T, B, P, H, C, M (check the full list)) | One key per tool, shown in the tooltip `editor.odin:70-80` (V, R, E, A, L, P, T, H, B, N, C) | Parity. Keep cliche's keys. |
| Tool options in a menu per tool | The bar shows the options of the tool, or of the selected shape `editor.odin:880` | cliche is faster. Keep. Add the fill colour and a custom colour to it. |
| Zoom percent and a zoom menu in the bottom bar | No zoom shown; Ctrl+0 = fit, no 100 % key | Show the percent in the bar; click opens a menu (fit, 50, 100, 200, 400 %); Ctrl+1 = 100 %. |
| Undo, redo | Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z; one step per gesture `editor_model.odin:16` | Parity. |
| Defaults: red, medium width, shadow on | Red, 4 px, shadow 3 `editor_model.odin:75` | Parity. |
| Options remembered across sessions | Yes `editor.odin:1053-1098` | Parity. |
| Move and resize any shape after drawing | Handles for boxes and lines `editor_model.odin:387`; Pen, Text, Step: move only | Add a scale handle to Text (changes `text_size`), Step (changes size), Pen (scales points). |
| Drawing tool can grab the selected shape | Yes: handles work with any tool `editor_model.odin:800` | Keep. |
| Right click on a shape removes it (region capture) (check) | Right click does nothing on the canvas `editor_model.odin:790` | Right click on a shape: context menu (delete, duplicate, to front, to back). |
| Step numbers auto-increment; start value and letters configurable | Auto-increment from the highest `editor_model.odin:336`; no start value | Add a start value and a format option to the Step's options. |
| Text: multi-line, font, outline / background | Inline field, single line, one font | Multi-line (Shift+Enter: new line); look: plain / outline / background. |
| Enter = run the after-capture tasks; Escape = close | Enter = Done; Escape deselects, then closes `editor.odin:756` | Parity; cliche is safer. |
| Ctrl+C copy, Ctrl+S save, Ctrl+Shift+S save as, Ctrl+U upload, Ctrl+P print (check) | Ctrl+C, Ctrl+S only | Add Ctrl+Shift+S, Ctrl+U, Ctrl+P, pin (Ctrl+Shift+P conflicts with the palette: choose Ctrl+T or a bar button). |
| Ctrl+V pastes an image or text as a shape | No paste | Add paste. |
| Z-order keys (Home / End / Page Up / Page Down) (check) | No z-order | Add with these keys. |
| Shift: square, circle, 45° | Yes `editor_model.odin:223-238` | Parity. |
| Arrow keys move the shape | Yes, Shift = 10 px `editor.odin:800` | Parity. |
| Space+drag or middle drag pans | Yes `editor_model.odin:785` | Parity. |
| Command palette, keys sheet | Ctrl+K, F1 `editor.odin:93-94` | cliche is better. |
| Region overlay: resize the region with the mouse | Keys only | Add handles (see 1.1). |
| One editor per picture; several open | `editor.odin:7-11` | cliche is better. |

## 3. Plan

### WP1: editor everyday gaps (P1)

Files: `editor_model.odin`, `editor.odin`, `editor_export.odin`, tests in `editor_model_test.odin`.

1. Zoom percent button and menu in the bar; Ctrl+1 = 100 %.
2. Custom colour (toolkit colour picker in a popover) and a separate fill colour (`Edit_Style.fill_color`).
3. Text: multi-line, look = plain / outline / background, bold.
4. Blur tool (`Edit_Tool.Blur`, blurred copy made on the chores like the mosaic), radius option; pixel size option for Pixelate.
5. Scale handle for Text, Step, Pen.
6. Ctrl+V: paste an image (new `Edit_Kind.Image`, its own texture) or text.
7. Right-click context menu; z-order (front, back, up, down); delete all.
8. Step: start value and format.

### WP2: editor output actions (P1, P2)

Status: written (Save as with the format and a quality setting, Upload, Pin on the toolkit's overlay window, JPEG /
WebP / BMP files and a file dropped on the editor, Print through the portal or PrintDlgW and GDI). Left: the history's
"Pin" action (`pin_picture(app, path)` is there for it) and a Pin workflow node (WP5); Print has no preview, no
scaling choice and one page; a JPEG's EXIF orientation is not applied.

Files: `editor.odin`, `editor_output.odin`, `worker.odin`, `save.odin`, a new `pin.odin`.

1. Save as: system dialog, format and quality (the `Save_Format` of `workflow_nodes.odin:55`).
2. Upload (Ctrl+U): default uploader, the URL goes to the clipboard and the history.
3. Pin to screen: an always-on-top window with the picture; drag moves, wheel zooms, Escape closes. Also a workflow node and a history action.
4. Open JPEG / WebP / BMP files in the editor; drop a file on the editor.
5. Print (P3): portal on Linux, the system dialog on Windows.

### WP3: capture and hotkeys (P1, P2)

Status: written (region grips, `--last-region`, `--all-screens`, `--color`, a workflow's own shortcut, a delay and the
pointer on the Capture node). The colour picker is a command and a shortcut, not a workflow's source: a colour is no
picture, and the Capture node gives a picture.

Files: `overlay.odin`, `geometry.odin`, `workflow.odin`, `shortcuts.odin`, `settings.odin`, `app.odin`.

1. Region handles: move and resize the chosen rectangle with the mouse; confirm with Enter or a double click.
2. Last region trigger.
3. Screen colour picker trigger (overlay + magnifier, click copies `#rrggbb`; Shift copies `rgb()`).
4. Shortcuts belong to workflows: each workflow can have its own key and source; a shortcut for "Capture a region and edit" by default.
5. All-screens source; delay as a Capture node parameter, with a countdown notification.
6. Cursor in screenshots (needs gt:capture support).

### WP4: editor tools for parity (P2, P3)

Status: written. The toolkit gained `draw.path_dash` and `image.cut_out`, `image.trim_bounds`, `image.edge_mean`.

Files: `editor_model.odin`, `editor_export.odin`, `editor.odin`; `gt:draw` for dashes, `gt:image` for the cut, the trim
and the eraser's colour.

1. Line style: done. `Edit_Style.dash` (solid, dashed, dotted) for rectangles, ellipses, lines, arrows, drawings,
   balloons and magnifiers; `draw.path_dash` cuts the path, the export draws through the same painter.
2. Done. `Edit_Style.radius` (a slider, 0 to 60 px); `Edit_Style.heads` (none, end, start, both) for arrows and
   drawings: a drawing with a head is the freehand arrow (no tool of its own: the Pen's option).
3. Done. `Edit_Kind.Balloon` (key Q): a rounded box, a tail whose tip is `Edit_Shape.c` with its own handle
   (`Edit_Handle.Tail`); its words are typed as soon as it is drawn, in the same undo step; it grows to hold them.
4. Done. `Edit_Kind.Magnify` (key M): the picture under it, 1.5, 2, 3 or 4 times larger, in a circle or a rectangle,
   with an edge. Decided: it magnifies the picture, not the annotations under it.
5. Done, through the Insert menu. A file (Ctrl+I: the system's dialog, decoded on the chores by `image.decode`) and the
   last screenshot (Ctrl+Shift+I) are `Edit_Kind.Image`. Decided: "from the screen" is the history's newest picture
   whose file is there, not a new region capture (the editor would hide behind its own overlay). The pointer
   (`Edit_Kind.Cursor`) is a vector arrow; an emoji (`Edit_Kind.Sticker`, 18 in the menu) is drawn from the font.
6. Done. `Edit_Kind.Eraser` (key X): a box of the mean colour of its edge (`image.edge_mean`), read again when it moves.
7. Done. The selection is a flag per shape (`Edit_Shape.picked`); a drag of Select on nothing picks what it touches,
   Shift+click adds or takes away, Ctrl+A picks all; a move, a property (what all the shapes picked share), the order,
   duplicate and delete apply to all; the handles show for one alone.
8. Done. The crop has handles with the Crop tool. The picture's own changes are a list in the document
   (`Edit_Doc.ops`: turn, mirror, resize, margins, a band cut out), undone as a gesture is; the shapes follow (letters
   stay upright); the window makes the picture again from the one taken, on the chores (`edit_picture_make`). Cut out
   (key K): a drag across removes columns, a drag down rows. Resize and margins: a dialog (width and height, the ratio
   kept or not; four margins and a colour). Auto crop (Ctrl+Shift+X): `image.trim_bounds` on the chores, then a crop.

### WP5: workflow nodes, uploads, tools (P2, P3)

Status: written, but for the decisions below.

Files: `workflow_nodes.odin`, `workflow_ops.odin`, `workflow_app.odin`, `workflow_run.odin`, `uploader.odin`,
`history_view.odin`; `gt:image` `combine` in the toolkit.

1. Nodes: Shorten URL (is.gd, v.gd, a `.sxcu` shortener), Open (an address or a file), Delete file, Ask (Yes/No action
   ports), Pin to the screen (a picture), Make QR code. Upload has a "done" action output, for a Delete file after it.
2. Triggers: Clipboard (`--upload-clipboard`) and Upload_File (`--upload-file`), both in the tray. The Capture node gives
   a picture, a file or a text, each on its own output; the Upload node takes any of them. The default workflow
   "Upload" runs for both.
3. A click on a run's notification opens its address, else its file. The toolkit had the click already (Linux: the
   "default" action; Windows: the toast's activation).
4. History: Open the URL, the tray's Recent submenu, the filter by date (a menu: today, 7 days, 30 days).
5. Image combiner (the history's selection), QR code generator (the Make QR code node). Scrolling capture, auto capture
   and the ruler: the decisions below.

#### Decisions

- **Scrolling capture: not now (L).** It takes three parts. (1) A stitcher, generic, in `gt:image`: frames of the same
  width, the overlap of each with the one before found by comparing rows (a hash per row, the longest run that
  matches), a fixed header and footer detected as rows that do not move, then one tall picture; tested on synthetic
  frames. (2) Scrolling the window under the pointer by a step, per system: Windows `SendInput` with `MOUSEEVENTF_WHEEL`;
  X11 XTest; Wayland only through the RemoteDesktop portal (libei), which asks the person each session. (3) A flow in
  cliche: the window chosen, scroll, `capture.window`, until two frames are the same or a count is reached, on the
  worker. Windows first; Wayland when the portal is worth its question.
- **Auto capture: not now (S).** It takes a thread that sleeps the interval and puts a trigger in the app's inbox (as a
  second start's command does: `app_message`), two preferences (the interval, the trigger) on the Capture page, and a
  tray item that starts and stops it. The loop needs no timeout: the thread wakes it. Nobody asked for it yet.
- **Ruler: not now (S).** The region overlay already says a rectangle's size while it is drawn. A ruler is a source as
  the colour picker is (`Source.Color`): the overlay with no rectangle, a drag draws a line with its length in pixels
  and its angle, Escape ends, nothing is captured. It touches `overlay.odin` and `flow.odin`, outside this lot.
- **Share URL (URLSharingService): not now (S).** The Shorten URL request already sends an address to a `.sxcu`; a
  sharing service is the same request with no address to read back.
