package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "cli"
import "core:testing"
import "http"
import "render"
import "template"
import "thumbnail"

send_vectored :: proc(conn: net.TCP_Socket, parts: [][]u8) -> bool {
	for part in parts {
		remaining := part
		for len(remaining) > 0 {
			sent, err := net.send_tcp(conn, remaining)
			if err != nil || sent == 0 {return false}
			remaining = remaining[sent:]
		}
	}
	return true
}

handle_mipmap :: proc(req: http.Header, conn: net.TCP_Socket) {
	defer net.close(conn)
	count, ok := strconv.parse_int(req.path[len("/mipmap/"):])
	if !ok || count <= 0 {
		net.send_tcp(
			conn,
			transmute([]u8)string("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"),
		)
		return
	}

	backing: []u8

	arena: mem.Arena
	alloc_err: mem.Allocator_Error

	backing, alloc_err = make([]u8, .5 * mem.Gigabyte, context.allocator)
	if alloc_err != nil {fmt.panicf("error %v", alloc_err)}

	defer delete(backing)
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)


	t_slice: []thumbnail.Thumb
	t_slice, alloc_err = make([]thumbnail.Thumb, len(library_images), alloc)
	if alloc_err != nil {fmt.panicf("error %v", alloc_err)}

	vectored_slice: [][]u8
	vectored_slice, alloc_err = make([][]u8, 3 + 9 * len(library_images), alloc)
	if alloc_err != nil {fmt.panicf("error %v", alloc_err)}

	for l, i in library_images {
		p := fmt.aprintf("./test/fixture/library/thumbnails/%v.webp", l.oid, allocator = alloc)
		t_bytes, _ := os.read_entire_file(p, alloc)

		t_slice[i] = thumbnail.Thumb{t_bytes, u16le(l.height), u16le(l.width)}
	}

	thumbnail.Thumbnail_MipMap(t_slice, vectored_slice, alloc)
	length := 0
	for part in vectored_slice {length += len(part)}
	header := fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: image/webp\r\nContent-Length: %d\r\n\r\n",
		length,
		allocator = alloc,
	)
	headers := [1][]u8{transmute([]u8)header}
	if !send_vectored(conn, headers[:]) {return}
	_ = send_vectored(conn, vectored_slice)
}

@(test)
test_mip :: proc(_: ^testing.T) {
	cfg := cli.getFlags()
	library_images = load_library(cfg.library)

	listener, _ := net.listen_tcp(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 0})
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, _ := net.dial_tcp(endpoint)
	defer net.close(client)
	conn, _, _ := net.accept_tcp(listener)
	handle_mipmap(http.Header{path = "/mipmap/3"}, conn)
}

MIN_LIMIT :: 10
VALID_SORTS := [4]string{"idAsc", "idDesc", "addedAtAsc", "addedAtDesc"}

//region: query parsing

Gallery_Query :: struct {
	limit:  int,
	offset: int,
	sort:   string,
	tags:   []string,
}

parse_int_param :: proc(values: []string) -> (out: int, ok: bool) {
	if len(values) == 0 {return 0, false}
	v, perr := strconv.parse_int(values[0])
	if !perr {return 0, false}
	return v, true
}

// parse_gallery_query parses limit/offset/sort/tags from a raw query string.
// Semantics follow ../lfs-booru/server.ts: invalid or small limit clamps to
// MIN_LIMIT; unknown sort falls back to idDesc; an invalid or negative offset
// marks the query invalid (caller returns 400).
parse_gallery_query :: proc(query: string) -> (q: Gallery_Query, ok: bool) {
	q = Gallery_Query {
		limit = MIN_LIMIT,
		sort  = "idDesc",
	}
	params := parse_query_params(query)
	defer delete(params)

	if values, ok_param := params["limit"]; ok_param {
		if n, parse_ok := parse_int_param(values[:]); parse_ok && n >= MIN_LIMIT {
			q.limit = n
		}
	}
	if values, ok_param := params["offset"]; ok_param {
		n, parse_ok := parse_int_param(values[:])
		if !parse_ok || n < 0 {
			return q, false
		}
		q.offset = n
	}
	if values, ok_param := params["sort"]; ok_param && len(values) > 0 {
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
	if values, ok_param := params["tags"]; ok_param {
		for value in values {
			for raw_tag in strings.split(value, ",") {
				tag := strings.trim_space(raw_tag)
				if tag == "" {continue}
				if seen[tag] {continue}
				seen[tag] = true
				append(&tags_dyn, tag)
			}
		}
	}
	q.tags = tags_dyn[:]
	return q, true
}

// parse_query_params splits a raw query string into a multimap. Keys and
// values are used as-is (no percent-decoding) -- see limitations.
parse_query_params :: proc(query: string) -> map[string][dynamic]string {
	params := make(map[string][dynamic]string)
	if query == "" {return params}
	for pair in strings.split(query, "&") {
		if pair == "" {continue}
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
	if len(tags) == 0 {return all}
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
	case "idAsc":
		return a.id < b.id
	case "idDesc":
		return a.id > b.id
	case "addedAtAsc":
		return a.added_at < b.added_at
	case "addedAtDesc":
		return a.added_at > b.added_at
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
page_slice :: proc(
	images: []template.Image,
	offset, limit: int,
) -> (
	page: []template.Image,
	has_more: bool,
) {
	if offset >= len(images) || offset < 0 {return images[:0], false}
	end := offset + limit
	if end < len(images) {
		return images[offset:end], true
	}
	if end > len(images) {end = len(images)}
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
	fragment_url = fmt.tprintf(
		"/fragment/gallery-content?limit=%d&sort=%s%s",
		q.limit,
		q.sort,
		tags_query,
	)
	return
}

//endregion

//region: page + fragment handlers

// handle_gallery serves "/" (alias) and "/gallery" -- the full page.
handle_gallery :: proc(req: http.Header, conn: net.TCP_Socket) {
	q, ok := parse_gallery_query(req.query)
	if !ok {
		{
			body := ""
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request",
				"text/plain; charset=utf-8",
				len(body),
				"",
				body,
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
	filter := template.Gallery_Filter {
		limit        = q.limit,
		sort         = q.sort,
		tags         = q.tags,
		offset       = q.offset + len(page),
		gallery_url  = gallery_url,
		fragment_url = fragment_url,
	}
	body := render.render_gallery_page("Gallery", render.Renderer_Version, filter, page, has_more)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK",
			"text/html; charset=utf-8",
			len(body),
			"",
			body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

// handle_fragment_gallery_content serves /fragment/gallery-content.
handle_fragment_gallery_content :: proc(req: http.Header, conn: net.TCP_Socket) {
	q, ok := parse_gallery_query(req.query)
	if !ok {
		{
			body := render.render_toast("invalid offset", .Error)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request",
				"text/html; charset=utf-8",
				len(body),
				"",
				body,
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
	filter := template.Gallery_Filter {
		limit        = q.limit,
		sort         = q.sort,
		tags         = q.tags,
		offset       = q.offset + len(page),
		gallery_url  = gallery_url,
		fragment_url = fragment_url,
	}
	body := render.render_gallery_content(filter, page, has_more)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK",
			"text/html; charset=utf-8",
			len(body),
			"",
			body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

// handle_fragment_items serves /fragment/items -- the load-more card grid.
handle_fragment_items :: proc(req: http.Header, conn: net.TCP_Socket) {
	q, ok := parse_gallery_query(req.query)
	if !ok {
		{
			body := render.render_toast("invalid offset", .Error)
			resp := fmt.tprintf(
				"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
				"400 Bad Request",
				"text/html; charset=utf-8",
				len(body),
				"",
				body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	filtered := filter_images(library_images, q.tags[:])
	sort_gallery(filtered, q.sort)
	page, has_more := page_slice(filtered, q.offset, q.limit)

	body := render.render_card_grid(
		{cards = page, offset = q.offset + len(page), has_more = has_more},
	)
	push_url := fmt.tprintf(
		"/gallery?limit=%d&offset=%d&sort=%s",
		q.limit,
		q.offset + len(page),
		q.sort,
	)
	{
		body := body
		resp := fmt.tprintf(
			"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
			"200 OK",
			"text/html; charset=utf-8",
			len(body),
			fmt.tprintf("HX-Push-Url: %s\r\n", push_url),
			body,
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
				"400 Bad Request",
				"text/html; charset=utf-8",
				len(body),
				"",
				body,
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
					"200 OK",
					"text/html; charset=utf-8",
					len(body),
					"",
					body,
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
			"404 Not Found",
			"text/html; charset=utf-8",
			len(body),
			"",
			body,
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
	if len(oid) == 0 || len(oid) > 128 {return false}
	for c in oid {
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {continue}
		return false
	}
	return true
}

static_mime :: proc(name: string) -> string {
	if strings.has_suffix(name, ".css") {return "text/css; charset=utf-8"}
	if strings.has_suffix(name, ".js") {return "text/javascript; charset=utf-8"}
	return "application/octet-stream"
}

handle_static :: proc(req: http.Header, conn: net.TCP_Socket) {
	resp: string
	rp := strings.split(req.path, "/")
	leaf := rp[len(rp) - 1]

	if strings.contains_any(leaf, "\\/\"'<>|&$`;:*? ") ||
	   len(leaf) < 3 ||
	   strings.contains(leaf, "..") {
		resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}

	local_fp := strings.join({"./static/", leaf}, "")
	data, err := os.read_entire_file(local_fp, context.temp_allocator)
	if err != nil {
		if err == os.General_Error.Not_Exist {
			resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
			return
		}

		fmt.printfln("error at handle_static: %v", err)

		resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
		return
	}
	header := fmt.tprintf(
		"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n",
		static_mime(leaf),
		len(data),
	)
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
				"404 Not Found",
				"text/plain; charset=utf-8",
				len(body),
				"",
				body,
			)
			net.send_tcp(conn, transmute([]u8)resp)
			net.close(conn)
		}
		return
	}

	thumb_fp := fmt.tprintf("%s/thumbnails/%s.webp", library_path, oid)
	data, err := os.read_entire_file(thumb_fp, context.temp_allocator)
	body := string(data)
	resp := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
		"200 OK",
		"image/webp",
		len(body),
		"",
		body,
	)
	net.send_tcp(conn, transmute([]u8)resp)
	net.close(conn)

	for img in library_images {
		if img.oid == oid {
			orig_fp := fmt.tprintf("%s/images/%s", library_path, oid)
			data, err := os.read_entire_file(orig_fp, context.temp_allocator)
			mime := img.content_type
			if mime == "" {mime = "application/octet-stream"}
			{
				body := string(data)
				resp := fmt.tprintf(
					"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s",
					"200 OK",
					mime,
					len(body),
					"",
					body,
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
			"404 Not Found",
			"text/plain; charset=utf-8",
			len(body),
			"",
			body,
		)
		net.send_tcp(conn, transmute([]u8)resp)
		net.close(conn)
	}
}

//endregion
