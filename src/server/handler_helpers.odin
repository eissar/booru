package server

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

import "../template"


MIN_LIMIT :: 10
VALID_SORTS := [4]string{"idAsc", "idDesc", "addedAtAsc", "addedAtDesc"}
// Returned to clients whose query string was not built with encodeURIComponent.
ENCODING_ERR_MSG :: "query strings must be encodeURIComponent-encoded; a bare \"+\" is not supported"

//region: query parsing

// Returns (-1, -1) for missing, invalid, or negative id/order parameters, and
// for a query that is not encodeURIComponent-encoded.
parse_regen_thumbnail_query :: proc(
	query: string,
	alloc := context.allocator,
) -> (
	id: int,
	order: int,
) {
	params := make(map[string]string, alloc)
	if !parse_query_params(query, &params, alloc) {return -1, -1}
	raw_id, has_id := params["id"]
	raw_order, has_order := params["order"]
	if !has_id || !has_order {return -1, -1}

	parsed_id, id_ok := parse_int_param(raw_id)
	parsed_order, order_ok := parse_int_param(raw_order)
	if !id_ok || !order_ok || parsed_id < 0 || parsed_order < 0 {return -1, -1}
	return parsed_id, parsed_order
}

Gallery_Query :: struct {
	limit:  int,
	offset: int,
	sort:   string,
	tags:   []string,
	search: string,
}

parse_int_param :: proc(value: string) -> (out: int, ok: bool) {
	if value == "" {return 0, false}
	v, perr := strconv.parse_int(value)
	if !perr {return 0, false}
	return v, true
}

// parse_gallery_query parses limit/offset/sort/tags/q from a raw query string.
// Semantics follow ../lfs-booru/server.ts: invalid or small limit clamps to
// MIN_LIMIT; unknown sort falls back to idDesc; an invalid or negative offset
// marks the query invalid (caller returns 400).
parse_gallery_query :: proc(
	query: string,
	alloc := context.allocator,
) -> (
	q: Gallery_Query,
	ok: bool,
) {
	q = Gallery_Query {
		limit = MIN_LIMIT,
		sort  = "idDesc",
	}
	params := make(map[string]string, alloc)
	if !parse_query_params(query, &params, alloc, combine_tags = true) {return q, false}
	if value, present := params["q"]; present {
		q.search = strings.trim_space(value)
	}

	if value, ok_param := params["limit"]; ok_param {
		if n, parse_ok := parse_int_param(value); parse_ok && n >= MIN_LIMIT {
			q.limit = n
		}
	}
	if value, ok_param := params["offset"]; ok_param {
		n, parse_ok := parse_int_param(value)
		if !parse_ok || n < 0 {
			return q, false
		}
		q.offset = n
	}
	if value, ok_param := params["sort"]; ok_param {
		for s in VALID_SORTS {
			if value == s {
				q.sort = s
				break
			}
		}
	}
	tags_dyn: [dynamic]string
	seen := make(map[string]bool)
	defer delete(seen)
	if value, ok_param := params["tags"]; ok_param {
		for raw_tag in strings.split(value, ",") {
			tag := strings.trim_space(raw_tag)
			if tag == "" {continue}
			if seen[tag] {continue}
			seen[tag] = true
			append(&tags_dyn, tag)
		}
	}
	q.tags = tags_dyn[:]
	return q, true
}

// parse_query_params splits a raw query string into a map of query values,
// writing into caller-owned params allocated from alloc (the request arena).
// Keys and values are percent-decoded. The first value for a repeated key wins.
//
// ok is false only for an encoding mismatch: query producers must be built with
// encodeURIComponent, which serializes space as %20 and a literal plus as %2B.
// A bare '+' therefore means the producer used RFC 3986 / form-urlencoded rules
// instead, where '+' is a space -- ambiguous with a real plus, so it is refused.
// The check reads the raw query, so an encoded %2B still decodes to a plus.
// A malformed %-sequence is also an encoding mismatch.
parse_query_params :: proc(
	query: string,
	params: ^map[string]string,
	alloc := context.allocator,
	combine_tags := false,
) -> (
	ok: bool,
) {
	if strings.index_byte(query, '+') >= 0 {return false}
	if query == "" {return true}
	for pair in strings.split(query, "&", allocator = alloc) {
		if pair == "" {continue}
		key, value := pair, ""
		if eq := strings.index_byte(pair, '='); eq >= 0 {
			key, value = pair[:eq], pair[eq + 1:]
		}
		key, ok = net.percent_decode(key, alloc)
		if !ok {return false}
		value, ok = net.percent_decode(value, alloc)
		if !ok {return false}
		if key in params {
			if combine_tags && key == "tags" {
				params[key] = fmt.aprintf("%s,%s", params[key], value, allocator = alloc)
			}
			continue
		}
		params[key] = value
	}
	return true
}

//region: filtering + sorting

// filter_urls builds the canonical chip URLs for the filter bar.
filter_urls :: proc(q: Gallery_Query) -> (gallery_url, fragment_url: string) {
	tags_query := ""
	for tag in q.tags {
		encoded := net.percent_encode(tag)
		tags_query = fmt.tprintf("%s&tags=%s", tags_query, encoded)
		delete(encoded)
	}
	if q.search != "" {
		encoded := net.percent_encode(q.search)
		defer delete(encoded)
		tags_query = fmt.tprintf("%s&q=%s", tags_query, encoded)
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

// Filter state lives in the filter bar, which existing htmx actions include.
gallery_filter_chips :: proc(q: Gallery_Query) -> []template.Filter_Chip {
	count := len(q.tags)
	if q.search != "" {count += 1}
	if count == 0 {return nil}
	chips := make([]template.Filter_Chip, count)
	index := 0
	if q.search != "" {
		without_search := q
		without_search.search = ""
		gallery_url, fragment_url := filter_urls(without_search)
		chips[index] = {
			key          = "q",
			value        = q.search,
			display      = fmt.tprintf("search: %s", q.search),
			gallery_url  = gallery_url,
			fragment_url = fragment_url,
		}
		index += 1
	}
	for tag, i in q.tags {
		remaining := make([]string, len(q.tags) - 1)
		copy(remaining[:i], q.tags[:i])
		copy(remaining[i:], q.tags[i + 1:])
		without_tag := q
		without_tag.tags = remaining
		gallery_url, fragment_url := filter_urls(without_tag)
		delete(remaining)
		chips[index] = {
			key          = "tags",
			value        = tag,
			display      = tag,
			gallery_url  = gallery_url,
			fragment_url = fragment_url,
		}
		index += 1
	}
	return chips
}

//endregion

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
	if strings.has_suffix(name, ".html") {return "text/html; charset=utf-8"}
	if strings.has_suffix(name, ".css") {return "text/css; charset=utf-8"}
	if strings.has_suffix(name, ".js") {return "text/javascript; charset=utf-8"}
	return "application/octet-stream"
}
