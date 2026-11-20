package test

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"
import curl "vendor:curl"

// libcurl's global init is not thread-safe; tests run in parallel threads.
@(init)
http_client_init :: proc "contextless" () {
	curl.global_init(curl.GLOBAL_DEFAULT)
}

@(fini)
http_client_fini :: proc "contextless" () {
	curl.global_cleanup()
}

// test_http sends one request in-process through libcurl, exercising the
// server's socket/parser/router as well as the handler, and expects the given
// HTTP status. unix_socket routes the request over that socket instead of TCP.
// The response body is allocated in context.temp_allocator.
test_http :: proc(
	t: ^testing.T,
	method, url, body: string,
	expected: int,
	content_type := "",
	unix_socket := "",
) -> (
	string,
	bool,
) {
	h := curl.easy_init()
	if !testing.expectf(t, h != nil, "%s %s: curl init failed", method, url) {return "", false}
	defer curl.easy_cleanup(h)

	out := make([dynamic]u8, context.temp_allocator)
	write :: proc "c" (buf: [^]byte, size, n: c.size_t, dst: rawptr) -> c.size_t {
		context = runtime.default_context()
		append((^[dynamic]u8)(dst), ..buf[:size * n])
		return size * n
	}
	headers: ^curl.slist
	defer curl.slist_free_all(headers)
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(h, .CUSTOMREQUEST, strings.clone_to_cstring(method, context.temp_allocator))
	curl.easy_setopt(h, .NOPROXY, cstring("*"))
	curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(1))
	curl.easy_setopt(h, .TIMEOUT, c.long(5))
	if unix_socket != "" {
		curl.easy_setopt(
			h,
			.UNIX_SOCKET_PATH,
			strings.clone_to_cstring(unix_socket, context.temp_allocator),
		)
	}
	if body != "" {
		curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
		curl.easy_setopt(h, .POSTFIELDS, raw_data(body))
	}
	if content_type != "" {
		headers = curl.slist_append(nil, fmt.ctprintf("Content-Type: %s", content_type))
		curl.easy_setopt(h, .HTTPHEADER, headers)
	}
	curl.easy_setopt(h, .WRITEFUNCTION, write)
	curl.easy_setopt(h, .WRITEDATA, &out)

	rc := curl.easy_perform(h)
	if !testing.expectf(t, rc == .E_OK, "%s %s: curl failed: %v", method, url, rc) {
		return "", false
	}
	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)
	ok := testing.expectf(
		t,
		int(status) == expected,
		"%s %s: expected HTTP %d, got %d",
		method,
		url,
		expected,
		status,
	)
	return string(out[:]), ok
}
