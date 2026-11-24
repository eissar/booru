package server

import "core:bufio"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:log"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../http"
import "../library"
import "../media"
import "../plugin/phash"
import "../progress"
import "../replay"
import pijul "../slop_pijul"
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
	q, ok := parse_gallery_query(req.header.query, req.alloc)
	if !ok {
		http.res_error("", res, .BadRequest); return
	}

	if q.until_id <= 0 {
		max_id, max_rc := store.read_max_item_id(s.data_store)
		if max_rc != sqlite.OK {
			http.res_error("", res, .InternalServerError)
			return
		}
		q.until_id = max_id
	}

	page, has_more, rc := store.search_images(
		s.data_store,
		q.search,
		q.tags[:],
		q.sort,
		q.offset,
		q.limit,
		req.alloc,
		q.until_id,
	)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}

	filter := template.Gallery_Filter {
		limit              = q.limit,
		until_id           = q.until_id,
		sort               = q.sort,
		tags               = q.tags,
		offset             = q.offset + len(page),
		extra_chips        = gallery_filter_chips(q, req.alloc),
		thumbnails_pending = progress.has_active(),
	}
	http.res_html(template.render_gallery_page("Gallery", filter, page, has_more, req.alloc), res)
}

// handle_fragment_gallery_content serves /fragment/gallery-content.
handle_fragment_gallery_content :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	q, ok := parse_gallery_query(req.header.query, req.alloc)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("invalid offset", .Error, req.alloc), res, .BadRequest)
		return
	}

	if q.until_id <= 0 {
		max_id, max_rc := store.read_max_item_id(s.data_store)
		if max_rc != sqlite.OK {
			http.res_error("", res, .InternalServerError)
			return
		}
		q.until_id = max_id
	}

	page, has_more, rc := store.search_images(
		s.data_store,
		q.search,
		q.tags[:],
		q.sort,
		q.offset,
		q.limit,
		req.alloc,
		q.until_id,
	)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}

	gallery_url, _ := filter_urls(q)
	filter := template.Gallery_Filter {
		limit       = q.limit,
		until_id    = q.until_id,
		sort        = q.sort,
		tags        = q.tags,
		offset      = q.offset + len(page),
		extra_chips = gallery_filter_chips(q, req.alloc),
	}
	res.headers["Hx-Push-Url"] = gallery_url
	http.res_html(template.render_gallery_content(filter, page, has_more, req.alloc), res)
}

// handle_fragment_items serves /fragment/items -- the load-more card grid.
handle_fragment_items :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	q, ok := parse_gallery_query(req.header.query, req.alloc)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("invalid offset", .Error, req.alloc), res, .BadRequest)
		return
	}

	if q.until_id <= 0 {
		max_id, max_rc := store.read_max_item_id(s.data_store)
		if max_rc != sqlite.OK {
			http.res_error("", res, .InternalServerError)
			return
		}
		q.until_id = max_id
	}

	page, has_more, rc := store.search_images(
		s.data_store,
		q.search,
		q.tags[:],
		q.sort,
		q.offset,
		q.limit,
		req.alloc,
		q.until_id,
	)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}

	gallery_url, _ := filter_urls(q)
	res.headers["Hx-Push-Url"] = gallery_url

	http.res_html(template.render_photo_grid(page, q.offset + len(page), has_more, req.alloc), res)
}

// handle_fragment_inspect serves /fragment/inspect/:id.
handle_fragment_inspect :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	id_str := req.header.path[len("/fragment/inspect/"):]
	id, ok := strconv.parse_int(id_str)
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Missing image id", .Error, req.alloc),
			res,
			.BadRequest,
		)
		return
	}
	params := make(map[string]string, req.alloc)
	if !parse_query_params(req.header.query, &params, req.alloc) {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast(ENCODING_ERR_MSG, .Error, req.alloc), res, .BadRequest)
		return
	}
	raw_order := params["order"]
	order, valid_order := parse_int_param(raw_order)
	if !valid_order {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Invalid render order", .Error, req.alloc),
			res,
			.BadRequest,
		)
		return
	}
	img, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if found {
		http.res_html(template.render_inspector(img, order, req.alloc), res)
		return
	}
	// not found
	res.headers["HX-Reswap"] = "beforeend"
	http.res_html(template.render_toast("Could not find image", .Error, req.alloc), res, .NotFound)
}

//endregion

//region: binary handlers

handle_static :: proc(res: ^http.Response, req: http.Req) {
	resp: string
	rp := strings.split(req.header.path, "/", req.alloc)
	leaf := rp[len(rp) - 1]

	// TODO spread these conditions out more
	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") ||
	   len(leaf) < 3 ||
	   strings.contains(leaf, "..") {

		http.res_html("", res, .NotFound)
		return
	}

	// Preserve nested asset paths while rejecting traversal and unsafe segments.
	relative := req.header.path[len("/static/"):]
	for segment in strings.split(relative, "/", req.alloc) {
		if segment == "" ||
		   strings.contains(segment, "..") ||
		   strings.contains_any(segment, "\\\\\"'<>|&$`;:*? ") {
			http.res_html("", res, .NotFound)
			return
		}
	}
	local_fp := strings.join({"./static/", relative}, "", req.alloc)
	data, err := os.read_entire_file(local_fp, req.alloc)
	if err != nil {
		if err == os.General_Error.Not_Exist {
			http.res_html("", res, .NotFound)
			return
		}

		log.debugf("error at handle_static: %v", err)

		http.res_html("", res, .InternalServerError)
		return
	}
	http.res_blob(data, res, mime_from_leaf(leaf))
}

// IMAGE_CSP applies only when an original is opened as a document (new tab,
// direct visit); <img>/<video> loads ignore it. It is a backstop in case a
// script-capable type (HTML, SVG) is ever accepted by ingest.
IMAGE_CSP :: "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'self'"

// handle_image serves /image/:oid -- the original file, located by library ID.
handle_image :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	oid := req.header.path[len("/image/"):]

	if !oid_path_safe(oid) {
		http.res_error("", res, .NotFound)
		return
	}

	img, found, rc := store.read_image_by_oid(s.data_store, oid, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		http.res_error("", res, .NotFound)
		return
	}

	fp := fmt.aprintf("%s/images/%d.%s", s.library_path, img.id, img.ext, allocator = req.alloc)
	file, open_err := os.open(fp, {.Read})
	if open_err != nil {
		http.res_error("", res, .NotFound)
		return
	}
	defer if file != nil {os.close(file)}

	size, size_err := os.file_size(file)
	if size_err != nil {
		http.res_error("", res, .InternalServerError)
		return
	}

	http.res_file(file, int(size), res)
	file = nil
	if img.content_type != "" {res.headers["Content-Type"] = img.content_type}
	res.headers["X-Content-Type-Options"] = "nosniff"
	res.headers["Content-Security-Policy"] = IMAGE_CSP
}

// handle_thumbnail serves /thumbnails/:res/:oid.webp from disk.
handle_thumbnail :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	rest := req.header.path[len("/thumbnails/"):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 {
		http.res_error("", res, .NotFound)
		return
	}
	res_name := rest[:slash]
	// Reject backslashes and dots so res_name cannot traverse upward from thumbnails/.
	if strings.contains_any(res_name, "\\.") {
		http.res_error("", res, .NotFound)
		return
	}
	leaf := rest[slash + 1:]
	if !strings.has_suffix(leaf, ".webp") {
		http.res_error("", res, .NotFound)
		return
	}
	oid := leaf[:len(leaf) - len(".webp")]
	if !oid_path_safe(oid) {
		http.res_error("", res, .NotFound)
		return
	}

	fp := fmt.aprintf(
		"%s/thumbnails/%s/%s.webp",
		s.library_path,
		res_name,
		oid,
		allocator = req.alloc,
	)
	data, err := os.read_entire_file(fp, req.alloc)
	if err != nil {
		http.res_error("", res, .NotFound)
		return
	}
	http.res_blob(data, res)
	res.headers["Content-Type"] = "image/webp"
	res.headers["X-Content-Type-Options"] = "nosniff"
	res.headers["Content-Security-Policy"] = IMAGE_CSP
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

	// Parse and validate IDs before touching the store.
	requested := make([dynamic]int, 0, requested_count, req.alloc)
	for raw_str_id in strings.split_iterator(&img_ids_raw, ",") {
		if raw_str_id == "" {continue}
		id, ok := strconv.parse_int(raw_str_id)
		if !ok {
			http.res_error("", res, status = .BadRequest)
			return
		}
		append(&requested, id)
	}

	if len(requested) == 0 {
		http.res_error("", res, status = .NotFound)
		return
	}

	oids, rc := store.read_oids_by_ids(s.data_store, requested[:], req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, status = .InternalServerError)
		return
	}

	thumbnails := make([]thumbnail.Thumb, len(oids), req.alloc)
	for oid, slot in oids {
		if oid == "" {
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

		thumbnails[slot] = thumbnail.Thumb{t_bytes, req_resolution, req_resolution}
	}

	prefix: webpx.Webp_Extended_Prefix
	length := webpx.Prepare_Webp_X(thumbnails, &prefix)
	// Retain the frames in the request allocator until the response is sent.
	data := new(Mipmap_Stream, req.alloc)
	data.files = thumbnails
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
	if req.header.method != "POST" {
		res.headers["Allow"] = "POST"
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Method not allowed", .Error, req.alloc),
			res,
			.MethodNotAllowed,
		)
		return
	}

	// Default response for malformed multipart input.
	res.headers["HX-Reswap"] = "beforeend"
	http.res_html(template.render_toast("Invalid upload", .Error, req.alloc), res, .BadRequest)

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
		disposition := strings.split(line[colon + 1:], ";", req.alloc)
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
			template.render_toast("Unsupported file type", .Error, req.alloc),
			res,
			.UnsupportedMediaType,
		)
		return
	}

	// Seeded from all historical creations at startup; exclusive creation still protects
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
			template.render_toast("Could not create original", .Error, req.alloc),
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
	if w, h, ok := media.probe_dimensions(data, format, path); ok {
		ev.width = int(w)
		ev.height = int(h)
	}

	ev.added_at = time.to_unix_nanoseconds(time.now()) / 1_000_000

	// update the event log
	append_err := elog.ev_append(s.event_log, []elog.Event{ev})
	if append_err != "" {
		// TODO: delete any uploaded files

		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Could not write original", .Error, req.alloc),
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

	replay.initiate_replay(s, full_replay = false)

	http.res_html(template.render_toast("Original saved", .Success, req.alloc), res, .Created)
}

handle_regen_thumbnail :: proc(s: ^library.State, res: ^http.Response, req: http.Req) {
	id, order := parse_regen_thumbnail_query(req.header.query, req.alloc)
	if id < 0 || order < 0 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("bad id or order query parameter", .Error, req.alloc),
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
			template.render_toast("could not find image with that id", .Error, req.alloc),
			res,
			.NotFound,
		)
		return
	}

	set := thumbnail.expected_resolutions(item.content_type)
	_, failed := thumbnail.force_generate_image_thumbnails(s^, item, set)
	if failed > 0 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not regenerate thumbnails", .Error, req.alloc),
			res,
			.InternalServerError,
		)
		return
	}

	http.res_html(template.render_item_card(item, order, req.alloc), res, .OK)
	return
}

handle_delete :: proc(s: ^library.State, res: ^http.Response, req: http.Req, body: []u8) {
	if req.header.method != "POST" {
		res.headers["Allow"] = "POST"
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Method not allowed", .Error, req.alloc),
			res,
			.MethodNotAllowed,
		)
		return
	}

	body := transmute(string)body

	parts, split_err := strings.split(body, "=", req.alloc)
	if split_err != nil || len(parts) != 2 || parts[0] != "id" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error, req.alloc), res, .BadRequest)
		return
	}
	raw_id := parts[1]
	id, ok := strconv.parse_int(raw_id)
	if !ok || id < 1 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error, req.alloc), res, .BadRequest)
		return
	}

	img, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("no match for ID", .Error, req.alloc), res, .NotFound)
		return
	}

	append_err := elog.ev_append(s.event_log, []elog.Event{{id = id, op = "delete"}})
	if append_err != "" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("could not write delete event", .Error, req.alloc),
			res,
			.InternalServerError,
		)
		return
	}

	replay.initiate_replay(s, full_replay = false)

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
	if req.header.method != "POST" {
		res.headers["Allow"] = "POST"
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("Method not allowed", .Error, req.alloc),
			res,
			.MethodNotAllowed,
		)
		return
	}

	params := make(map[string]string, req.alloc)
	if !parse_query_params(string(body), &params, req.alloc) {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast(ENCODING_ERR_MSG, .Error, req.alloc), res, .BadRequest)
		return
	}
	raw_id := params["id"]
	id, id_ok := parse_int_param(raw_id[:])
	if !id_ok || id < 1 {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad id", .Error, req.alloc), res, .BadRequest)
		return
	}

	// Tags are lowercased with whitespace runs as '-'; anything else outside
	// is_allowed_tag_char is rejected rather than canonicalized.
	tags := make([dynamic]string, req.alloc)
	for raw in form_tags(params["tags"], req.alloc) {
		tag := library.lowercase_and_dash_whitespace(raw, req.alloc)
		if tag == "" || strings.index_proc(tag, elog.is_allowed_tag_char, false) != -1 {
			res.headers["HX-Reswap"] = "beforeend"
			http.res_html(
				template.render_toast(fmt.tprintf("invalid tag %q", raw), .Error, req.alloc),
				res,
				.BadRequest,
			)
			return
		}
		if !slice.contains(tags[:], tag) {append(&tags, tag)}
	}

	ok := true
	name := form_string(params, "name", &ok)
	_, name_present := params["name"]
	if !utf8.valid_string(name) {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("name must be valid UTF-8", .Error, req.alloc),
			res,
			.BadRequest,
		)
		return
	}
	comment := form_string(params, "comment", &ok)
	_, comment_present := params["comment"]
	path := form_string(params, "path", &ok)
	if value, present := params["path"]; present && strings.trim_space(value) == "" {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(
			template.render_toast("path must not be empty", .Error, req.alloc),
			res,
			.BadRequest,
		)
		return
	}
	ext := form_string(params, "ext", &ok)
	content_type := form_string(params, "content_type", &ok)
	mtime := form_i64(params, "mtime", &ok)
	added_at := form_i64(params, "added_at", &ok)
	width := int(form_i64(params, "width", &ok))
	height := int(form_i64(params, "height", &ok))
	if !ok {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("bad metadata", .Error, req.alloc), res, .BadRequest)
		return
	}

	current, found, rc := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !found {
		res.headers["HX-Reswap"] = "beforeend"
		http.res_html(template.render_toast("no match for ID", .Error, req.alloc), res, .NotFound)
		return
	}

	// Serve is synchronous: no other writer can interleave this read/append/apply.
	// Commutative changes emit a patch event; LWW replacements emit an overwrite event.
	delta := make([dynamic]string, req.alloc)
	if _, present := params["tags"]; present {
		for tag in current.tags {
			if !slice.contains(tags[:], tag) {append(&delta, tag)}
		}
		for tag in tags {
			if !slice.contains(current.tags, tag) {append(&delta, tag)}
		}
	}
	patch_ev := elog.Event {
		id   = id,
		op   = "patch",
		tags = delta[:],
	}
	if name_present && current.name != name {
		patch_ev.name = elog.name_delta(current.name, name, req.alloc)
	}
	if comment_present && current.comment != comment {
		patch_ev.comment = pijul.generate_patch(current.comment, comment, req.alloc)
	}
	if mtime > current.mtime {patch_ev.mtime = mtime}
	if added_at > current.added_at {patch_ev.added_at = added_at}

	patch_changed :=
		len(delta) != 0 ||
		patch_ev.name != "" ||
		patch_ev.comment != "" ||
		patch_ev.mtime != 0 ||
		patch_ev.added_at != 0

	overwrite_ev := elog.Event {
		id = id,
		op = "overwrite",
	}
	if path != "" && path != current.path {overwrite_ev.path = path}
	if ext != "" && ext != current.ext {overwrite_ev.ext = ext}
	if content_type != "" &&
	   content_type != current.content_type {overwrite_ev.content_type = content_type}
	if width != 0 && width != current.width {overwrite_ev.width = width}
	if height != 0 && height != current.height {overwrite_ev.height = height}

	overwrite_changed :=
		overwrite_ev.path != "" ||
		overwrite_ev.ext != "" ||
		overwrite_ev.content_type != "" ||
		overwrite_ev.width != 0 ||
		overwrite_ev.height != 0

	if patch_changed || overwrite_changed {
		batch := make([dynamic]elog.Event, req.alloc)
		if patch_changed {append(&batch, patch_ev)}
		if overwrite_changed {append(&batch, overwrite_ev)}
		if err := elog.ev_append(s.event_log, batch[:]); err != "" {
			res.headers["HX-Reswap"] = "beforeend"
			http.res_html(
				template.render_toast("could not write metadata event", .Error, req.alloc),
				res,
				.BadRequest,
			)
			return
		}
		replay.initiate_replay(s, full_replay = false)
	}

	img, _, rc2 := store.read_image_by_id(s.data_store, id, req.alloc)
	if rc2 != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	// Card tag forms target their own tag list; inspector forms (and plain
	// POSTs without HX-Target) retain the existing full-inspector response.
	for name, target in req.header.headers {
		if strings.equal_fold(name, "HX-Target") && target != "" && target != "inspector-content" {
			http.res_html(template.render_card_tags(img.tags, req.alloc), res)
			return
		}
	}
	http.res_html(template.render_inspector(img, 0, req.alloc), res)
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
form_tags :: proc(value: string, alloc := context.allocator) -> []string {
	out := make([dynamic]string, alloc)
	for part in strings.split(value, ",", alloc) {
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
	case strings.has_suffix(name, ".svg"):
		return .Svg
	case strings.has_suffix(name, ".webp"):
		return .Webp
	case:
		return .Octet_Stream
	}
}

// handle_sse_progress serves "/events/progress" -- scan progress as HTML fragments.
handle_sse_progress :: proc(res: ^http.Response) {
	http.res_event_stream(progress_stream, nil, res)
}

// handle_duplicates renders the duplicate comparison and merge page synchronously.
handle_duplicates :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	if req.header.method != "GET" {
		http.res_text("method not allowed", res, .MethodNotAllowed)
		return
	}

	pairs, ok := phash.find_all_duplicates(s.data_store, alloc = req.alloc)
	if !ok {
		http.res_error("duplicate scan failed", res, .InternalServerError)
		return
	}

	// Build connected components via union-find so overlapping pairs merge into one group.
	id_to_idx := make(map[int]int, len(pairs) * 2, req.alloc)
	parent := make([dynamic]int, 0, len(pairs) * 2, req.alloc)
	ids := make([dynamic]int, 0, len(pairs) * 2, req.alloc)
	comp_dist := make([dynamic]int, 0, len(pairs) * 2, req.alloc)

	find_root :: proc(parent: []int, x: int) -> int {
		cur := x
		for parent[cur] != cur {
			parent[cur] = parent[parent[cur]]
			cur = parent[cur]
		}
		return cur
	}

	intern_id :: proc(
		id_to_idx: ^map[int]int,
		parent, ids, comp_dist: ^[dynamic]int,
		id: int,
	) -> int {
		if idx, exists := id_to_idx[id]; exists {
			return idx
		}
		idx := len(ids)
		id_to_idx[id] = idx
		append(parent, idx)
		append(ids, id)
		append(comp_dist, 0)
		return idx
	}

	for p in pairs {
		ia := intern_id(&id_to_idx, &parent, &ids, &comp_dist, p.id_a)
		ib := intern_id(&id_to_idx, &parent, &ids, &comp_dist, p.id_b)
		ra := find_root(parent[:], ia)
		rb := find_root(parent[:], ib)
		if ra != rb {
			parent[rb] = ra
			if comp_dist[rb] > comp_dist[ra] {
				comp_dist[ra] = comp_dist[rb]
			}
		}
		if p.dist > comp_dist[ra] {
			comp_dist[ra] = p.dist
		}
	}

	comp_items := make(map[int][dynamic]library.Image, len(pairs), req.alloc)
	for id, idx in ids {
		img, img_ok, rc := store.read_image_by_id(s.data_store, id, req.alloc)
		if rc != sqlite.OK {
			http.res_error("", res, .InternalServerError)
			return
		}
		if !img_ok {continue}
		root := find_root(parent[:], idx)
		if root not_in comp_items {
			comp_items[root] = make([dynamic]library.Image, 0, 4, req.alloc)
		}
		append(&comp_items[root], img)
	}

	groups := make([dynamic]template.Duplicate_Group_View, 0, len(comp_items), req.alloc)
	for root, items in comp_items {
		if len(items) < 2 {continue}
		slice.sort_by(items[:], proc(a, b: library.Image) -> bool {return a.id < b.id})

		first := items[0]
		first_tags := slice.clone(first.tags, context.temp_allocator)
		slice.sort(first_tags)
		first_tags_joined := strings.join(first_tags, ",", context.temp_allocator)

		identical := true
		for item in items[1:] {
			if item.name != first.name || item.comment != first.comment {
				identical = false
				break
			}
			t := slice.clone(item.tags, context.temp_allocator)
			slice.sort(t)
			if strings.join(t, ",", context.temp_allocator) != first_tags_joined {
				identical = false
				break
			}
		}

		append(
			&groups,
			template.Duplicate_Group_View {
				gid = first.id,
				items = items[:],
				max_dist = comp_dist[root],
				identical = identical,
			},
		)
	}
	slice.sort_by(
		groups[:],
		proc(a, b: template.Duplicate_Group_View) -> bool {return a.gid < b.gid},
	)

	http.res_html(template.render_duplicates_page(groups[:], allocator = req.alloc), res)
}

// handle_merge serves POST /merge: merges each comma-separated `from` id into
// `into`, in order, and deletes the sources. Patch tags are toggles (txor), so
// only tags `into` lacks are logged; `into`'s name wins, and a differing source
// name and the source comment are appended to `into`'s comment.
handle_merge :: proc(s: ^library.State, res: ^http.Response, req: http.Req, body: []u8) {
	if req.header.method != "POST" {
		http.res_text("method not allowed", res, .MethodNotAllowed)
		return
	}
	params := make(map[string]string, req.alloc)
	if !parse_query_params(string(body), &params, req.alloc) {
		http.res_error(ENCODING_ERR_MSG, res, .BadRequest)
		return
	}
	if DEV_ROUTES && params["sample"] == "1" {
		http.res_text("", res, .OK)
		return
	}
	into_id, into_ok := parse_int_param(params["into"])
	if !into_ok || into_id < 1 {
		http.res_error("bad id", res, .BadRequest)
		return
	}
	from_ids := make([dynamic]int, req.alloc)
	for part in strings.split(params["from"], ",", req.alloc) {
		id, ok := parse_int_param(strings.trim_space(part))
		if !ok || id < 1 || id == into_id || slice.contains(from_ids[:], id) {
			http.res_error("bad id", res, .BadRequest)
			return
		}
		append(&from_ids, id)
	}

	into_img, into_found, rc := store.read_image_by_id(s.data_store, into_id, req.alloc)
	if rc != sqlite.OK {
		http.res_error("", res, .InternalServerError)
		return
	}
	if !into_found {
		http.res_error("no match for ID", res, .NotFound)
		return
	}
	tags := slice.clone_to_dynamic(into_img.tags, req.alloc)
	delta := make([dynamic]string, req.alloc)
	comment := into_img.comment
	froms := make([dynamic]library.Image, 0, len(from_ids), req.alloc)
	for id in from_ids {
		img, found, from_rc := store.read_image_by_id(s.data_store, id, req.alloc)
		if from_rc != sqlite.OK {
			http.res_error("", res, .InternalServerError)
			return
		}
		if !found {
			http.res_error("no match for ID", res, .NotFound)
			return
		}
		append(&froms, img)
		for tag in img.tags {
			if !slice.contains(tags[:], tag) {
				append(&tags, tag)
				append(&delta, tag)
			}
		}
		lines := [2]string{"", img.comment}
		if img.name != into_img.name {
			lines[0] = fmt.aprintf("merged #%d name=%q", id, img.name, allocator = req.alloc)
		}
		for line in lines {
			if line == "" || strings.contains(comment, line) {continue}
			sep := comment == "" || strings.has_suffix(comment, "\n") ? "" : "\n"
			comment = strings.concatenate({comment, sep, line}, req.alloc)
		}
	}

	events := make([dynamic]elog.Event, 0, len(froms) + 1, req.alloc)
	patch_ev := elog.Event {
		id   = into_id,
		op   = "patch",
		tags = delta[:],
	}
	if comment != into_img.comment {
		patch_ev.comment = pijul.generate_patch(into_img.comment, comment, req.alloc)
	}
	if len(delta) != 0 || patch_ev.comment != "" {append(&events, patch_ev)}
	for img in froms {append(&events, elog.Event{id = img.id, op = "delete"})}

	if append_err := elog.ev_append(s.event_log, events[:]); append_err != "" {
		http.res_error("could not write merge events", res, .InternalServerError)
		return
	}
	replay.initiate_replay(s, full_replay = false)
	for img in froms {
		pth := fmt.aprintf(
			"%s/images/%d.%s",
			s.library_path,
			img.id,
			img.ext,
			allocator = req.alloc,
		)
		if remove_err := os.remove(pth); remove_err != nil {
			fmt.eprintfln("ERROR merge: remove original %s: %v", pth, remove_err)
		}
	}
	http.res_text("", res, .OK)
}

@(private = "file")
progress_stream :: proc(conn: ^net.TCP_Socket, _: rawptr) -> io.Error {
	for {
		entries := progress.snapshot(context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		for p in entries {
			done_attr := " class=\"is-done\"" if p.done else ""
			if total, ok := p.total.?; ok {
				fmt.sbprintf(
					&sb,
					"<progress%s value=\"%d\" max=\"%d\"></progress><div class=\"thumbnail-progress-meta\"><span>%s</span><span>%d / %d</span></div>",
					done_attr,
					p.finished,
					total,
					p.phase,
					p.finished,
					total,
				)
			} else {
				fmt.sbprintf(
					&sb,
					"<div class=\"thumbnail-progress-meta\"><span>%s</span><span>%d</span></div>",
					p.phase,
					p.finished,
				)
			}
		}
		if len(entries) > 0 {
			if err := http.sse_event(conn, "progress", strings.to_string(sb)); err != nil {
				return err
			}
		}
		if !progress.has_active() {return http.sse_event(conn, "done", "<span>done</span>")}
		time.sleep(250 * time.Millisecond)
		free_all(context.temp_allocator)
	}
}
