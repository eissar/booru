package server

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
import "../template"
import "../thumbnail"


//region: page + fragment handlers

// handle_gallery serves "/" (alias) and "/gallery" -- the full page.
handle_gallery :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		http.res_error("", res, .BadRequest); return
	}

	filtered := filter_images(s.library_images[:], q.tags[:])
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
	}
	http.res_html(template.render_gallery_page("Gallery", filter, page, has_more), res)
}

// handle_fragment_gallery_content serves /fragment/gallery-content.
handle_fragment_gallery_content :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		http.res_html(template.render_toast("invalid offset", .Error), res, .BadRequest)
		return
	}

	filtered := filter_images(s.library_images[:], q.tags[:])
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
	}
	res.headers["Hx-Push-Url"] = gallery_url
	http.res_html(template.render_gallery_content(filter, page, has_more), res)
}

// handle_fragment_items serves /fragment/items -- the load-more card grid.
handle_fragment_items :: proc(s: library.State, res: ^http.Response, req: http.Req) {
	context.allocator = req.alloc
	q, ok := parse_gallery_query(req.header.query)
	if !ok {
		http.res_html(template.render_toast("invalid offset", .Error), res)
		return
	}

	filtered := filter_images(s.library_images[:], q.tags[:])
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
		http.res_html(template.render_toast("Missing image id", .Error), res, .BadRequest)
		return
	}
	for img in s.library_images {
		if img.id == id {
			http.res_html(template.render_inspector(img), res)
			return
		}
	}
	// not found
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
	for img in s.library_images {
		if img.oid != oid {continue}
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
		if dir_err != nil {break}
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
	prefix: thumbnail.Webp_Extended_Prefix,
}

send_mipmap_stream :: proc(conn: ^net.TCP_Socket, raw: rawptr) -> io.Error {
	data := cast(^Mipmap_Stream)raw
	return thumbnail.Webp_X(data.files, &data.prefix, conn)
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
		query := req.header.query
		if !strings.has_prefix(query, "ids=") {
			http.res_error("", res, status = .BadRequest)
			return
		}
		img_ids_raw, _ = strings.replace_all(query[len("ids="):], "%2C", ",", req.alloc)
	}
	requested_count := strings.count(img_ids_raw, ",") + 1

	thumbnails := make([dynamic]thumbnail.Thumb, requested_count, req.alloc)
	defer delete(thumbnails)

	idx := 0
	for raw_str_id in strings.split_iterator(&img_ids_raw, ",") {
		if raw_str_id == "" {continue}
		slot := idx
		idx += 1
		id, ok := strconv.parse_int(raw_str_id)
		if !ok {
			http.res_error("", res, status = .BadRequest)
			return
		}

		oid, found := lookup_thumbnail_oid_by_id(s, id)
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
	prefix: thumbnail.Webp_Extended_Prefix
	length := thumbnail.Prepare_Webp_X(thumbnails[:idx], &prefix)
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
	//HACK retain uploaded metadata outside the request arena; ownership is unresolved.
	state_alloc := context.allocator
	context.allocator = req.alloc
	if req.header.method != "POST" {
		res.headers["Allow"] = "POST"
		http.res_html(template.render_toast("Method not allowed", .Error), res, .MethodNotAllowed)
		return
	}

	// Default response for malformed multipart input.
	http.res_html(template.render_toast("Invalid upload", .Error), res, .BadRequest)

	content_type := ""
	for name, value in req.header.headers {
		if strings.equal_fold(name, "Content-Type") {
			content_type = value
			break
		}
	}
	params := strings.split(content_type, ";")
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
	opening := fmt.aprintf("--%s\r\n", boundary)
	if !strings.has_prefix(raw, opening) {return}
	raw = raw[len(opening):]
	header_end := strings.index(raw, "\r\n\r\n")
	if header_end < 0 {return}

	is_image := false
	filename := ""
	for line in strings.split(raw[:header_end], "\r\n") {
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
	delimiter := fmt.aprintf("\r\n--%s", boundary)
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
		http.res_html(
			template.render_toast("Unsupported file type", .Error),
			res,
			.UnsupportedMediaType,
		)
		return
	}

	// Seeded from loaded images at startup; exclusive creation still protects
	// originals without event-log entries from being overwritten after restart.
	ev: library.Event
	library.new_add_event(&ev)
	id := ev.id
	path := fmt.aprintf("%s/images/%d.%s", s.library_path, id, media.extension(format))
	file, err := os.open(path, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if err != nil {
		fmt.eprintfln("ingest: open %s: %v", path, err)
		http.res_html(
			template.render_toast("Could not create original", .Error),
			res,
			.InternalServerError,
		)
		return
	}

	_, write_err := os.write(file, data)
	close_err := os.close(file)
	if write_err != nil || close_err != nil {
		fmt.eprintfln("ingest: write %s: %v; close: %v", path, write_err, close_err)
		os.remove(path)
		http.res_html(
			template.render_toast("Could not write original", .Error),
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

	ev.oid = string(hex.encode(digest[:], state_alloc))
	ev.path = strings.clone(path, state_alloc)
	leaf := filename
	for c, i in filename {
		if c == '/' || c == '\\' {leaf = filename[i + 1:]}
	}
	if dot := strings.index_byte(leaf, '.'); dot >= 0 {leaf = leaf[:dot]}
	ev.name = strings.clone(leaf, state_alloc)
	ev.ext = media.extension(format)
	ev.contentType = media.mime(format)
	// TODO: Read the media dimensions; width and height should not remain zero.

	//HACK copy the slice and retain its old backing allocation.
	images := make([]library.Image, len(s.library_images) + 1, state_alloc)
	copy(images, s.library_images)
	images[len(images) - 1] = library.Image {
		id           = ev.id,
		oid          = ev.oid,
		path         = ev.path,
		ext          = ev.ext,
		tags         = ev.tags,
		width        = ev.width,
		height       = ev.height,
		name         = ev.name,
		mtime        = ev.mtime,
		added_at     = ev.addedAt,
		content_type = ev.contentType,
	}
	s.library_images = images

	http.res_html(template.render_toast("Original saved", .Success), res, .Created)
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
