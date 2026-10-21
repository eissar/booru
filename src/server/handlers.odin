package server

import "core:bufio"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../http"
import "../library"
import "../media"
import "../store"
import "../template"
import "../thumbnail"
import "../thumbnail/webpx"
import "../util"
import "../vendor/sqlite"

import elog "../event_log"


//region: page + fragment handlers

// handle_gallery serves "/" (alias) and "/gallery" -- the full page.
handle_gallery :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		http.res_error("", res, .BadRequest); return
	}

	images, rc := store.search_images(s.data_store, q.search, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	filtered := filter_images(images, q.tags[:])
	defer delete(filtered)
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	gallery_url, fragment_url := filter_urls(q)
	filter := template.Gallery_Filter {
		limit        = q.limit,
		sort         = q.sort,
		tags         = q.tags,
		offset       = q.offset + len(page),
		gallery_url  = gallery_url,
		fragment_url = fragment_url,
		extra_chips  = gallery_filter_chips(q),
	}
	http.res_html(template.render_gallery_page("Gallery", filter, page, has_more), res)
}

// handle_fragment_gallery_content serves /fragment/gallery-content.
handle_fragment_gallery_content :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("invalid offset", .Error), res, .BadRequest)
		return
	}

	images, rc := store.search_images(s.data_store, q.search, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	filtered := filter_images(images, q.tags[:])
	defer delete(filtered)
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	gallery_url, fragment_url := filter_urls(q)
	filter := template.Gallery_Filter {
		limit        = q.limit,
		sort         = q.sort,
		tags         = q.tags,
		offset       = q.offset + len(page),
		gallery_url  = gallery_url,
		fragment_url = fragment_url,
		extra_chips  = gallery_filter_chips(q),
	}
	res.headers["Hx-Push-Url"] = gallery_url
	http.res_html(template.render_gallery_content(filter, page, has_more), res)
}

// handle_fragment_items serves /fragment/items -- the load-more card grid.
handle_fragment_items :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("invalid offset", .Error), res, .BadRequest)
		return
	}

	images, rc := store.search_images(s.data_store, q.search, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	filtered := filter_images(images, q.tags[:])
	defer delete(filtered)
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	gallery_url, _ := filter_urls(q)
	res.headers["Hx-Push-Url"] = gallery_url

	http.res_html(template.render_photo_grid(page, q.offset + len(page), has_more), res)
}

// handle_fragment_inspect serves /fragment/inspect/:id.
handle_fragment_inspect :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	id_str := req.header.path[len("/fragment/inspect/"):]
	id, ok := strconv.parse_int(id_str)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("Missing image id", .Error), res, .BadRequest)
		return
	}
	params := make(map[string]string)
	if !parse_query_params(req.header.query, &params) {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast(ENCODING_ERR_MSG, .Error), res, .BadRequest)
		return
	}
	raw_order := params["order"]
	order, valid_order := parse_int_param(raw_order)
	if !valid_order {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("Invalid render order", .Error), res, .BadRequest)
		return
	}
	img, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if found {
		http.res_html(template.render_inspector(img, order), res)
		return
	}
	// not found
	res.headers["HX-Reswap"] = "beforeend"
	http.res_html(template.render_toast("Could not find image", .Error), res, .NotFound)
}

//endregion

//region: binary handlers

handle_static :: proc(res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	resp: string
	rp := strings.split(req.header.path, "/")
	leaf := rp[len(rp) - 1]

	// TODO spread these conditions out more
	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") ||
	   len(leaf) < 3 ||
	   strings.contains(leaf, "..") {

		http.res_html("", res, .NotFound)
		return
	}

	local_fp := strings.join({"./static/", leaf}, "")
	data, err := os.read_entire_file(local_fp, req.alloc)
	if err != nil {
		if err == os.General_Error.Not_Exist {
			http.res_html("", res, .NotFound)
			return
		}

		fmt.printfln("error at handle_static: %v", err)

		http.res_html("", res, .InternalServerError)
		return
	}
	http.res_blob(data, res, mime_from_leaf(leaf))
}

// handle_image serves /image/:oid -- thumbnails first, then originals by library ID.
handle_image :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	oid := req.header.path[len("/image/"):]

	if !oid_path_safe(oid) {
		http.res_error("", res, .NotFound)
		return
	}

	thumb_buf: [4096]u8
	thumb_fp :=
		len(s.library_path) + len(oid) + len("/thumbnails/.webp") <= len(thumb_buf) ? fmt.bprintf(thumb_buf[:], "%s/thumbnails/%s.webp", s.library_path, oid) : fmt.aprintf("%s/thumbnails/%s.webp", s.library_path, oid, allocator = req.alloc)
	data, err := os.read_entire_file(thumb_fp, req.alloc)
	if err == nil {
		http.res_blob(data, res, .Webp)
		return
	}
	img, found, rc := store.read_image_by_oid(s.data_store, oid, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if found {
		dir_buf: [4096]u8
		dir :=
			len(s.library_path) + len("/images") <= len(dir_buf) ? fmt.bprintf(dir_buf[:], "%s/images", s.library_path) : fmt.aprintf("%s/images", s.library_path, allocator = req.alloc)
		path_buf: [4096]u8
		if img.ext != "" {
			data, err = os.read_entire_file(
				len(dir) + len(img.ext) + 22 <= len(path_buf) ? fmt.bprintf(path_buf[:], "%s/%d.%s", dir, img.id, img.ext) : fmt.aprintf("%s/%d.%s", dir, img.id, img.ext, allocator = req.alloc),
				req.alloc,
			)
			if err == nil {
				http.res_blob(data, res)
				if img.content_type != "" {res.headers["Content-Type"] = img.content_type}
				return
			}
		}
		entries, dir_err := os.read_directory_by_path(dir, -1, req.alloc)
		if dir_err != nil {
			http.res_error("", res, .NotFound)
			return
		}
		defer os.file_info_slice_delete(entries, req.alloc)
		// A signed 64-bit integer needs at most 20 bytes, plus the dot.
		prefix_buf: [21]u8
		prefix := fmt.bprintf(prefix_buf[:], "%d.", img.id)
		for entry in entries {
			if entry.type != .Regular || !strings.has_prefix(entry.name, prefix) {continue}
			data, err = os.read_entire_file(
				len(dir) + len(entry.name) + 1 <= len(path_buf) ? fmt.bprintf(path_buf[:], "%s/%s", dir, entry.name) : fmt.aprintf("%s/%s", dir, entry.name, allocator = req.alloc),
				req.alloc,
			)
			if err != nil {continue}
			http.res_blob(data, res)
			if img.content_type != "" {res.headers["Content-Type"] = img.content_type}
			return
		}
	}
	http.res_error("", res, .NotFound)
}

Mipmap_Stream :: struct {
	files:  []thumbnail.Thumb,
	prefix: webpx.Webp_Extended_Prefix,
}

send_mipmap_stream :: proc(conn: ^net.TCP_Socket, raw: rawptr) -> (err: io.Error) {
	data := cast(^Mipmap_Stream)raw

	buffer: [4 * 1024]u8

	writer: bufio.Writer
	bufio.writer_init_with_buf(&writer, socket_writer(conn), buffer[:])
	out_stream := bufio.writer_to_writer(&writer)
	defer {
		// works with implicit return
		if err == nil {
			err = bufio.writer_flush(&writer)
		}
	}

	return webpx.Encode(data.files, &data.prefix, out_stream)

}

handle_mipmap :: proc(
	s: library.State,
	res: ^http.Response,
	req: http.Req,
	raw_req_body: []u8 = nil,
) {
	// 64|128
	req_resolution: u16le
	raw_resolution := req.header.path[len("/mipmap/"):]
	if raw_resolution == "64" {req_resolution = 64}
	if raw_resolution == "128" {req_resolution = 128}

	if !slice.contains([]string{"64", "128"}, req.header.path[len("/mipmap/"):]) {
		res.headers["Server-Timing"] = fmt.aprintf(
			"app;dur=%.2f",
			time.duration_milliseconds(time.since(req.rec_time)),
			allocator = req.alloc,
		)

		http.res_error("", res, status = .BadRequest)
		return
	}

	// IDs come from the POST body, or from "?ids=1,2,3" so that the same batch
	// can be fetched with a GET (e.g. <link rel="preload" as="fetch">).
	img_ids_raw := transmute(string)raw_req_body
	if len(raw_req_body) == 0 {
		params := make(map[string]string, req.alloc)
		defer delete(params)
		if !parse_query_params(req.header.query, &params, req.alloc) {
			http.res_error(ENCODING_ERR_MSG, res, status = .BadRequest)
			return
		}
		img_ids_raw = params["ids"]
	}
	requested_count := strings.count(img_ids_raw, ",") + 1

	// Reject malformed IDs before touching the store.
	validate := img_ids_raw
	for raw_str_id in strings.split_iterator(&validate, ",") {
		if raw_str_id == "" {continue}
		if _, ok := strconv.parse_int(raw_str_id); !ok {
			http.res_error("", res, status = .BadRequest)
			return
		}
	}

	thumbnails := make([dynamic]thumbnail.Thumb, requested_count, req.alloc)
	defer delete(thumbnails)

	idx := 0
	for raw_str_id in strings.split_iterator(&img_ids_raw, ",") {
		if raw_str_id == "" {continue}
		slot := idx
		idx += 1
		id, _ := strconv.parse_int(raw_str_id)

		oid, found, rc := lookup_thumbnail_oid_by_id(s, id, req.alloc)
		if rc != sqlite.OK {
			http.res_error("", res, status = .InternalServerError)
			return
		}
		if !found {
			thumbnails[slot] = thumbnail.new_not_found_thumb(req_resolution)
			continue
		}

		p := fmt.aprintf(
			"%s/thumbnails/%s/%s.webp",
			s.library_path,
			raw_resolution,
			oid,
			allocator = req.alloc,
		)
		t_bytes, err := os.read_entire_file(p, req.alloc)
		if err != nil {
			// fmt.eprintfln("thumbnail id=%v read failed path=%s err=%v", id, p, err)
			thumbnails[slot] = thumbnail.new_not_found_thumb(req_resolution)
			continue
		}

		// TODO: enrich output of lookup_thumbnail_oid_by_id
		// or something; need to retrieve actual thumbnail dims;
		thumbnails[slot] = thumbnail.Thumb{t_bytes, req_resolution, req_resolution}
	}

	if idx == 0 {
		http.res_error("", res, status = .NotFound)
		return
	}
	prefix: webpx.Webp_Extended_Prefix
	length := webpx.Prepare_Webp_X(thumbnails[:idx], &prefix)
	// Retain the frames in the request allocator until the response is sent.
	data := new(Mipmap_Stream, req.alloc)
	data.files = make([]thumbnail.Thumb, idx, req.alloc)
	copy(data.files, thumbnails[:idx])
	data.prefix = prefix
	res.body = nil
	res.body_stream = send_mipmap_stream
	res.body_stream_data = data
	res.body_stream_length = length


	res.headers["Server-Timing"] = fmt.aprintf(
		"app;dur=%.2f",
		time.duration_milliseconds(time.since(req.rec_time)),
		allocator = req.alloc,
	)

	res.headers["Content-Type"] = http.CONTENT_TYPE_MIME[.Webp]
	res.status = .OK
}

//region: ingest

// handle_ingest serves POST /ingest -- one multipart file into the library.
// Responds with a toast fragment for #toasts-log.
handle_ingest :: proc(s: ^library.State, res: ^http.Response, req: http.Req, body: []u8) {
	context.allocator = req.alloc
	if req.header.method != "POST" {
		res.headers["Allow"] = "POST"
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("Method not allowed", .Error), res, .MethodNotAllowed)
		return
	}

	// Default response for malformed multipart input.
	res.headers["HX-Reswap"] = "beforeend"
	http.res_html(template.render_toast("Invalid upload", .Error), res, .BadRequest)

	content_type := ""
	for name, value in req.header.headers {
		if strings.equal_fold(name, "Content-Type") {
			content_type = value
			break
		}
	}
	params := strings.split(content_type, ";", req.alloc)
	if len(params) != 2 ||
	   !strings.equal_fold(strings.trim_space(params[0]), "multipart/form-data") {
		return
	}
	param := strings.trim_space(params[1])
	eq := strings.index_byte(param, '=')
	if eq < 0 || !strings.equal_fold(strings.trim_space(param[:eq]), "boundary") {
		return
	}
	boundary := strings.trim_space(param[eq + 1:])
	if len(boundary) >= 2 && boundary[0] == '"' && boundary[len(boundary) - 1] == '"' {
		boundary = boundary[1:len(boundary) - 1]
	}
	if len(boundary) == 0 || len(boundary) > 70 || strings.contains_any(boundary, "\r\n") {
		return
	}

	raw := transmute(string)body
	opening := fmt.aprintf("--%s\r\n", boundary, allocator = req.alloc)
	if !strings.has_prefix(raw, opening) {return}
	raw = raw[len(opening):]
	header_end := strings.index(raw, "\r\n\r\n")
	if header_end < 0 {return}

	is_image := false
	filename := ""

	for line in strings.split(raw[:header_end], "\r\n", req.alloc) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {return}
		if !strings.equal_fold(strings.trim_space(line[:colon]), "Content-Disposition") {
			continue
		}
		disposition := strings.split(line[colon + 1:], ";")
		if !strings.equal_fold(strings.trim_space(disposition[0]), "form-data") {
			return
		}
		for attribute in disposition[1:] {
			attribute := strings.trim_space(attribute)
			if attribute == "name=\"image\"" {
				is_image = true
			}
			if len(attribute) >= len("filename=\"\"") &&
			   strings.has_prefix(attribute, "filename=\"") &&
			   strings.has_suffix(attribute, "\"") {
				filename = attribute[len("filename=\""):len(attribute) - 1]
			}
		}
	}
	if !is_image {return}

	raw = raw[header_end + 4:]
	delimiter := fmt.aprintf("\r\n--%s", boundary, allocator = req.alloc)
	end := -1
	for offset := 0; offset < len(raw); {
		i := strings.index(raw[offset:], delimiter)
		if i < 0 {break}
		i += offset
		tail := raw[i + len(delimiter):]
		if tail == "--" || tail == "--\r\n" {
			end = i
			break
		}
		// Another part, or a closing delimiter with unexpected trailing data.
		if strings.has_prefix(tail, "\r\n") || strings.has_prefix(tail, "--") {
			return
		}
		offset = i + len(delimiter)
	}
	if end <= 0 {return}
	data := transmute([]u8)raw[:end]

	format := media.detect_format(data)
	if format == .Unknown {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Unsupported file type", .Error),
			res,
			.UnsupportedMediaType,
		)
		return
	}

	// Seeded from loaded images at startup; exclusive creation still protects
	// originals without event-log entries from being overwritten after restart.
	ev: elog.Event
	library.new_add_event(&ev)
	id := ev.id
	path := fmt.aprintf(
		"%s/images/%d.%s",
		s.library_path,
		id,
		media.extension(format),
		allocator = req.alloc,
	)
	if err := util.atomic_write(path, data, replace_existing = false); err != nil {
		fmt.eprintfln("ingest: atomic write %s: %v", path, err)
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Could not create original", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, data)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&hash, digest[:], finalize_clone = false)

	ev.oid = string(hex.encode(digest[:], req.alloc))
	ev.path = strings.clone(path, req.alloc)
	leaf := filename
	for c, i in filename {
		if c == '/' || c == '\\' {leaf = filename[i + 1:]}
	}
	if dot := strings.index_byte(leaf, '.'); dot >= 0 {leaf = leaf[:dot]}
	ev.name = strings.clone(leaf, req.alloc)
	ev.ext = media.extension(format)
	ev.content_type = media.mime(format)
	// TODO: Read the media dimensions; width and height should not remain zero.

	ev.added_at = time.to_unix_nanoseconds(time.now()) / 1_000_000

	// update the event log
	append_err := elog.event_append(s.event_log, ev)
	if append_err != "" {
		// TODO: delete any uploaded files

		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Could not write original", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	// Sync the published original exactly once, after appending its event.
	file, file_err := os.open(path, {.Write}, os.Permissions_Default)
	if file_err != nil {fmt.panicf("ingest: open original for syncing: %v", file_err)}
	defer os.close(file)
	if err := os.sync(file); err != nil {
		fmt.panicf("ingest: sync original %s: %v", path, err)
	}
	when ODIN_OS == .Linux {
		images_dir := fmt.aprintf("%s/images", s.library_path, allocator = req.alloc)
		dir, dir_err := os.open(images_dir, {.Read}, os.Permissions_Default)
		if dir_err != nil {fmt.panicf("ingest: open images directory for syncing: %v", dir_err)}
		defer os.close(dir)
		if err := os.sync(dir); err != nil {
			fmt.panicf("ingest: sync images directory: %v", err)
		}
	}

	item := library.Image {
		id           = ev.id,
		oid          = ev.oid,
		path         = ev.path,
		ext          = ev.ext,
		tags         = ev.tags,
		width        = ev.width,
		height       = ev.height,
		name         = ev.name,
		comment      = ev.comment,
		mtime        = ev.mtime,
		added_at     = ev.added_at,
		content_type = ev.content_type,
	}
	if rc := store.insert_into_items(s.data_store, item); rc != sqlite.OK {
		fmt.panicf("ingest: apply event to store: rc=%v", rc)
	}

	http.res_html(template.render_toast("Original saved", .Success), res, .Created)
}

handle_regen_thumbnail :: proc(s: ^library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc

	id, order := parse_regen_thumbnail_query(req.header.query)
	if id < 0 || order < 0 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("bad id or order query parameter", .Error),
			res,
			.BadRequest,
		)
		return
	}

	item, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not find image with that id", .Error),
			res,
			.NotFound,
		)
		return
	}

	set := bit_set[thumbnail.LOD_RESOLUTION]{.x128, .x64}
	_, failed := thumbnail.force_generate_image_thumbnails(s^, item, set)
	if failed > 0 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not regenerate thumbnails", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	http.res_html(template.render_item_card(item, order), res, .OK)
	return
}

handle_delete :: proc(s: ^library.State, res: ^http.Response, req: http.Req, body: []u8) {
	body := transmute(string)body

	parts, split_err := strings.split(body, "=", req.alloc)
	if split_err != nil || len(parts) != 2 || parts[0] != "id" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error), res, .BadRequest)
		return
	}
	raw_id := parts[1]
	id, ok := strconv.parse_int(raw_id)
	if !ok || id < 1 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error), res, .BadRequest)
		return
	}

	img, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("no match for ID", .Error), res, .NotFound)
		return
	}

	append_err := elog.event_append(s.event_log, elog.Event{id = id, op = "delete"})
	if append_err != "" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not write delete event", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	// Log first, then apply to the store.
	if sqlite.with_transaction(s.data_store, id, store.delete_item) != sqlite.OK {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not apply delete event", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	pth := fmt.aprintf("%s/images/%d.%s", s.library_path, id, img.ext, allocator = req.alloc)
	// TODO: a failed original removal is logged but still returns 200. Originals
	// may be stored on remote storage or other filesystems (proxied mode), and
	// as long as the delete event is written to the event log, queries are
	// eventually consistent. Remote/proxied originals aren't represented in the
	// codebase yet but probably will be. Open question: how failures should be
	// retried or reconciled later.
	// TODO: maybe a different success code: 202 (accepted, not necessarily
	// complete; htmx still swaps it) vs 200. Avoid 204: htmx skips the swap, so
	// hx-swap="delete" would leave the card. 404/410 for already-deleted is
	// undecided.
	if remove_err := os.remove(pth); remove_err != nil {
		fmt.eprintfln("ERROR delete: remove original %s: %v", pth, remove_err)
	}

	http.res_text("", res, .OK)
}


// handle_update_metadata serves POST /update-metadata (inspector name form).
// Logs a "patch" event first, then applies it to the store.
handle_update_metadata :: proc(s: ^library.State, res: ^http.Response, req: http.Req, body: []u8) {
	context.allocator = req.alloc
	params := make(map[string]string)
	if !parse_query_params(string(body), &params, req.alloc) {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast(ENCODING_ERR_MSG, .Error), res, .BadRequest)
		return
	}
	raw_id := params["id"]
	id, id_ok := parse_int_param(raw_id[:])
	if !id_ok || id < 1 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error), res, .BadRequest)
		return
	}

	// Full patch format: every field is optional; empty/zero leaves it alone.
	ev := elog.Event {
		id   = id,
		op   = "patch",
		tags = form_tags(params["tags"]),
	}
	ok := true
	ev.name = form_string(params, "name", &ok)
	ev.comment = form_string(params, "comment", &ok)
	ev.oid = form_string(params, "oid", &ok)
	ev.path = form_string(params, "path", &ok)
	ev.ext = form_string(params, "ext", &ok)
	ev.content_type = form_string(params, "content_type", &ok)
	ev.mtime = form_i64(params, "mtime", &ok)
	ev.added_at = form_i64(params, "added_at", &ok)
	ev.width = int(form_i64(params, "width", &ok))
	ev.height = int(form_i64(params, "height", &ok))
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad metadata", .Error), res, .BadRequest)
		return
	}

	_, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("no match for ID", .Error), res, .NotFound)
		return
	}

	if elog.event_append(s.event_log, ev) != "" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not write patch event", .Error),
			res,
			.InternalServerError,
		)
		return
	}
	patch := library.Image {
		id           = id,
		oid          = ev.oid,
		path         = ev.path,
		ext          = ev.ext,
		name         = ev.name,
		comment      = ev.comment,
		content_type = ev.content_type,
		mtime        = ev.mtime,
		added_at     = ev.added_at,
		width        = ev.width,
		height       = ev.height,
		tags         = ev.tags,
	}
	if sqlite.with_transaction(s.data_store, patch, store.patch_item) != sqlite.OK {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not apply patch event", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	img, _, rc2 := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc2 != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	http.res_html(template.render_inspector(img, 0), res)
}

// form_string returns the decoded, trimmed value of a urlencoded form key ("" if absent).
form_string :: proc(params: map[string]string, key: string, ok: ^bool) -> string {
	return strings.trim_space(params[key])
}

form_i64 :: proc(params: map[string]string, key: string, ok: ^bool) -> i64 {
	v := form_string(params, key, ok)
	if v == "" {return 0}
	n, parsed := strconv.parse_i64(v)
	if !parsed {ok^ = false}
	return n
}

// form_tags splits an already percent-decoded, comma-separated tags value.
form_tags :: proc(value: string) -> []string {
	out := make([dynamic]string)
	for part in strings.split(value, ",") {
		t := strings.trim_space(part)
		if t != "" {append(&out, t)}
	}
	return out[:]
}

mime_from_leaf :: proc(name: string) -> http.Content_Type {
	switch {
	case strings.has_suffix(name, ".html"):
		return .Html
	case strings.has_suffix(name, ".css"):
		return .Css
	case strings.has_suffix(name, ".js"):
		return .Javascript
	case:
		return .Octet_Stream
	}
}
