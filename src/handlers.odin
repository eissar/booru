package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "http"
import "render"
import "template"

MIN_LIMIT :: 10
VALID_SORTS := [4]string{"idAsc", "idDesc", "addedAtAsc", "addedAtDesc"}

//region: query parsing

Gallery_Query :: struct {
	limit:  int,
	offset: int,
	sort:   string,
	tags:   []string,
	valid:  bool, // false => invalid offset supplied
}

parse_int_param :: proc(values: []string) -> (out: int, ok: bool) {
	if len(values) == 0 { return 0, false }
	v, perr := strconv.parse_int(values[0])
	if !perr { return 0, false }
	return v, true
}

// parse_gallery_query parses limit/offset/sort/tags from a raw query string.
// Semantics follow ../lfs-booru/server.ts: invalid or small limit clamps to
// MIN_LIMIT; unknown sort falls back to idDesc; an invalid or negative offset
// marks the query invalid (caller returns 400).
parse_gallery_query :: proc(query: string) -> Gallery_Query {
	q := Gallery_Query{limit = MIN_LIMIT, sort = "idDesc", valid = true}
	params := parse_query_params(query)
	defer delete(params)

	if values, ok := params["limit"]; ok {
		if n, ok := parse_int_param(values[:]); ok && n >= MIN_LIMIT {
			q.limit = n
		}
	}
	if values, ok := params["offset"]; ok {
		n, ok := parse_int_param(values[:])
		if !ok || n < 0 {
			q.valid = false
			return q
		}
		q.offset = n
	}
	if values, ok := params["sort"]; ok && len(values) > 0 {
		for s in VALID_SORTS {
			if values[0] == s {
				q.sort = s
				break
			}
		}
	}
	tags_dyn: [dynamic]string
	seen := make(map[string]bool)
	defer delete(seen)
	if values, ok := params["tags"]; ok {
		for value in values {
			for raw_tag in strings.split(value, ",") {
				tag := strings.trim_space(raw_tag)
				if tag == "" { continue }
				if seen[tag] { continue }
				seen[tag] = true
				append(&tags_dyn, tag)
			}
		}
	}
	q.tags = tags_dyn[:]
	return q
}

// parse_query_params splits a raw query string into a multimap. Keys and
// values are used as-is (no percent-decoding) -- see limitations.
parse_query_params :: proc(query: string) -> map[string][dynamic]string {
	params := make(map[string][dynamic]string)
	if query == "" { return params }
	for pair in strings.split(query, "&") {
		if pair == "" { continue }
		key, value := pair, ""
		if eq := strings.index_byte(pair, '='); eq >= 0 {
			key, value = pair[:eq], pair[eq + 1:]
		}
		if _, ok := params[key]; !ok {
			params[key] = make([dynamic]string, 0, 1)
		}
		append(&params[key], value)
	}
	return params
}

//region: filtering + sorting

// filter_images returns the images carrying every requested tag.
filter_images :: proc(all: []template.Image, tags: []string) -> []template.Image {
	if len(tags) == 0 { return all }
	out := make([dynamic]template.Image, 0, len(all))
	for img in all {
		matched := 0
		for want in tags {
			for tag in img.tags {
				if tag == want {
					matched += 1
					break
				}
			}
		}
		if matched == len(tags) {
			append(&out, img)
		}
	}
	return out[:]
}

less_img :: proc(a, b: template.Image, sort: string) -> bool {
	switch sort {
	case "idAsc":       return a.id < b.id
	case "idDesc":      return a.id > b.id
	case "addedAtAsc":  return a.added_at < b.added_at
	case "addedAtDesc": return a.added_at > b.added_at
	}
	return a.id > b.id
}

// sort_gallery sorts the slice in place by the named sort parameter.
sort_gallery :: proc(images: []template.Image, sort: string) {
	for i := 1; i < len(images); i += 1 {
		j := i
		for j > 0 && less_img(images[j], images[j - 1], sort) {
			images[j], images[j - 1] = images[j - 1], images[j]
			j -= 1
		}
	}
}

// page_slice slices images[offset:offset+limit] and reports whether more
// items follow the page.
page_slice :: proc(images: []template.Image, offset, limit: int) -> (page: []template.Image, has_more: bool) {
	if offset >= len(images) || offset < 0 { return images[:0], false }
	end := offset + limit
	if end < len(images) {
		return images[offset:end], true
	}
	if end > len(images) { end = len(images) }
	return images[offset:end], false
}

// filter_urls builds the canonical chip URLs for the filter bar.
filter_urls :: proc(q: Gallery_Query) -> (gallery_url, fragment_url: string) {
	tags_query := ""
	for tag, i in q.tags[:] {
		if i == 0 {
			tags_query = fmt.tprintf("&tags=%s", tag)
		} else {
			tags_query = fmt.tprintf("%s&tags=%s", tags_query, tag)
		}
	}
	gallery_url = fmt.tprintf("/gallery?limit=%d&sort=%s%s", q.limit, q.sort, tags_query)
	fragment_url = fmt.tprintf("/fragment/gallery-content?limit=%d&sort=%s%s", q.limit, q.sort, tags_query)
	return
}

//endregion

//region: page + fragment handlers

// handle_gallery serves "/" (alias) and "/gallery" -- the full page.
handle_gallery :: proc(req: http.Header, conn: net.TCP_Socket) {
	q := parse_gallery_query(req.query)
	if !q.valid {
		{
			body := ""
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request", "text/plain; charset=utf-8", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	filtered := filter_images(library_images, q.tags[:])
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	gallery_url, fragment_url := filter_urls(q)
	filter := template.Gallery_Filter{
		limit         = q.limit,
		sort          = q.sort,
		tags          = q.tags,
		offset        = q.offset + len(page),
		gallery_url   = gallery_url,
		fragment_url  = fragment_url,
	}
	body := render.render_gallery_page("Gallery", render.Renderer_Version, filter, page, has_more)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK", "text/html; charset=utf-8", len(body), "", body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

// handle_fragment_gallery_content serves /fragment/gallery-content.
handle_fragment_gallery_content :: proc(req: http.Header, conn: net.TCP_Socket) {
	q := parse_gallery_query(req.query)
	if !q.valid {
		{
			body := render.render_toast("invalid offset", .Error)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request", "text/html; charset=utf-8", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	filtered := filter_images(library_images, q.tags[:])
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	gallery_url, fragment_url := filter_urls(q)
	filter := template.Gallery_Filter{
		limit         = q.limit,
		sort          = q.sort,
		tags          = q.tags,
		offset        = q.offset + len(page),
		gallery_url   = gallery_url,
		fragment_url  = fragment_url,
	}
	body := render.render_gallery_content(filter, page, has_more)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK", "text/html; charset=utf-8", len(body), "", body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

// handle_fragment_items serves /fragment/items -- the load-more card grid.
handle_fragment_items :: proc(req: http.Header, conn: net.TCP_Socket) {
	q := parse_gallery_query(req.query)
	if !q.valid {
		{
			body := render.render_toast("invalid offset", .Error)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request", "text/html; charset=utf-8", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	filtered := filter_images(library_images, q.tags[:])
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	body := render.render_card_grid({cards = page, offset = q.offset + len(page), has_more = has_more})
	push_url := fmt.tprintf("/gallery?limit=%d&offset=%d&sort=%s", q.limit, q.offset + len(page), q.sort)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK", "text/html; charset=utf-8", len(body), fmt.tprintf("HX-Push-Url: %s\r\n", push_url), body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

// handle_fragment_inspect serves /fragment/inspect/:id.
handle_fragment_inspect :: proc(req: http.Header, conn: net.TCP_Socket) {
	id_str := req.path[len("/fragment/inspect/"):]
	id, ok := strconv.parse_int(id_str)
	if !ok {
		{
			body := render.render_toast("Missing image id", .Error)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request", "text/html; charset=utf-8", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}
	for img in library_images {
		if img.id == id {
			{
				body := render.render_inspector(img)
				resp := fmt.tprintf(
					"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
					"200 OK", "text/html; charset=utf-8", len(body), "", body,
				)
				net.send_tcp(conn, transmute([]u8)resp)
				net.close(conn)
			}
			return
		}
	}
	{
		body := render.render_toast("Could not find image", .Error)
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"404 Not Found", "text/html; charset=utf-8", len(body), "", body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

//endregion

//region: binary handlers

// oid_path_safe rejects anything that is not a plain object id (hex), which
// also rules out path traversal.
oid_path_safe :: proc(oid: string) -> bool {
	if len(oid) == 0 || len(oid) > 128 { return false }
	for c in oid {
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') { continue }
		return false
	}
	return true
}

static_mime :: proc(name: string) -> string {
	if strings.has_suffix(name, ".css") { return "text/css; charset=utf-8" }
	if strings.has_suffix(name, ".js") { return "text/javascript; charset=utf-8" }
	return "application/octet-stream"
}

handle_static :: proc(req: http.Header, conn: net.TCP_Socket) {
	resp: string
	rp := strings.split(req.path, "/")
	leaf := rp[len(rp) - 1]

	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") || len(leaf) < 3 || strings.contains(leaf, "..") {
		resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}

	local_fp := strings.join({"./static/", leaf}, "")
	data, success := os.read_entire_file(local_fp)
	if !success {
		resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}
	header := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n", static_mime(leaf), len(data))
	net.send_tcp(conn, transmute([]u8)header)
	net.send_tcp(conn, data)
	net.close(conn)
}

// handle_image serves /image/:oid -- thumbnails first (webp), then originals
// by oid, mirroring ../lfs-booru/server.ts.
handle_image :: proc(req: http.Header, conn: net.TCP_Socket) {
	oid := req.path[len("/image/"):]
	if !oid_path_safe(oid) {
		{
			body := ""
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"404 Not Found", "text/plain; charset=utf-8", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	thumb_fp := fmt.tprintf("%s/thumbnails/%s.webp", library_path, oid)
	if data, ok := os.read_entire_file(thumb_fp); ok {
		{
			body := string(data)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"200 OK", "image/webp", len(body), "", body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	for img in library_images {
		if img.oid == oid {
			orig_fp := fmt.tprintf("%s/images/%s", library_path, oid)
			if data, ok := os.read_entire_file(orig_fp); ok {
				mime := img.content_type
				if mime == "" { mime = "application/octet-stream" }
				{
					body := string(data)
					resp := fmt.tprintf(
						"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
						"200 OK", mime, len(body), "", body,
					)
					net.send_tcp(conn, transmute([]u8)resp)
					net.close(conn)
				}
				return
			}
			{
				body := ""
				resp := fmt.tprintf(
					"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
					"404 Not Found", "text/plain; charset=utf-8", len(body), "", body,
				)
				net.send_tcp(conn, transmute([]u8)resp)
				net.close(conn)
			}
			return
		}
	}
	{
		body := ""
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"404 Not Found", "text/plain; charset=utf-8", len(body), "", body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

//endregion
