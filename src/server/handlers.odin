package server

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../http"
import "../library"
import "../template"
import "../thumbnail"


//region: page + fragment handlers

// handle_gallery serves "/" (alias) and "/gallery" -- the full page.
handle_gallery :: proc(s: library.State, res: ^http.Response, req: http.Header) {
	q, ok := parse_gallery_query(req.query)
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
handle_fragment_gallery_content :: proc(s: library.State, res: ^http.Response, req: http.Header) {
	q, ok := parse_gallery_query(req.query)
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
handle_fragment_items :: proc(s: library.State, res: ^http.Response, req: http.Header) {
	q, ok := parse_gallery_query(req.query)
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
handle_fragment_inspect :: proc(s: library.State, res: ^http.Response, req: http.Header) {
	id_str := req.path[len("/fragment/inspect/"):]
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

handle_static :: proc(res: ^http.Response, req: http.Header) {
	resp: string
	rp := strings.split(req.path, "/")
	leaf := rp[len(rp) - 1]

	// TODO spread these conditions out more
	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") ||
	   len(leaf) < 3 ||
	   strings.contains(leaf, "..") {

		http.res_html("", res, .NotFound)
		return
	}

	local_fp := strings.join({"./static/", leaf}, "")
	data, err := os.read_entire_file(local_fp, context.temp_allocator)
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
handle_image :: proc(s: library.State, res: ^http.Response, req: http.Header) {
	oid := req.path[len("/image/"):]

	if !oid_path_safe(oid) {
		http.res_error("", res, .NotFound)
		return
	}

	thumb_fp := fmt.tprintf("%s/thumbnails/%s.webp", s.library_path, oid)
	data, err := os.read_entire_file(thumb_fp, context.temp_allocator)
	if err == nil {
		http.res_blob(data, res, .Webp)
		return
	}
	for img in s.library_images {
		if img.oid != oid {continue}
		dir := fmt.tprintf("%s/images", s.library_path)
		if img.ext != "" {
			data, err = os.read_entire_file(
				fmt.tprintf("%s/%d.%s", dir, img.id, img.ext),
				context.temp_allocator,
			)
			if err == nil {
				http.res_blob(data, res)
				if img.content_type != "" {res.headers["Content-Type"] = img.content_type}
				return
			}
		}
		entries, dir_err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if dir_err != nil {break}
		defer os.file_info_slice_delete(entries, context.temp_allocator)
		prefix := fmt.tprintf("%d.", img.id)
		for entry in entries {
			if entry.type != .Regular || !strings.has_prefix(entry.name, prefix) {continue}
			data, err = os.read_entire_file(
				fmt.tprintf("%s/%s", dir, entry.name),
				context.temp_allocator,
			)
			if err != nil {continue}
			http.res_blob(data, res)
			if img.content_type != "" {res.headers["Content-Type"] = img.content_type}
			return
		}
	}
	http.res_error("", res, .NotFound)
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
			"%s/thumbnails/%s/%v.webp",
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
	parts := thumbnail.Thumbnail_MipMap(thumbnails[:idx], req.alloc)
	length := 0
	for part in parts {length += len(part)}

	res.body = make([]u8, length, req.alloc)
	offset := 0
	for part in parts {
		offset += copy(res.body[offset:], part)
	}


	res.headers["Server-Timing"] = fmt.aprintf(
		"app;dur=%.2f",
		time.duration_milliseconds(time.since(req.rec_time)),
		allocator = req.alloc,
	)

	res.headers["Content-Type"] = http.CONTENT_TYPE_MIME[.Webp]
	res.status = .OK
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
