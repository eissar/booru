package http

import "base:runtime"
import "core:testing"

// TODO: When reusing request buffers, reset them only after response sending completes.
Response :: struct {
	headers: map[string]string,
	body:    []u8,
	status:  STATUS,
}

// REGION: asserts
@(test)
unit_smoke_res_helper :: proc(t: ^testing.T) {
	res: Response
	defer delete(res.headers)

	reset :: proc(res: ^Response) {
		delete(res.headers)
		res^ = Response {
			headers = make(map[string]string, 8),
		}
	}

	reset(&res)
	res_text("hello", &res)

	reset(&res)
	blob := [3]u8{1, 2, 3}
	res_blob(blob[:], &res)

	reset(&res)
	res_html(transmute([]u8)string("<p>hello</p>"), &res)

	reset(&res)
	res_json(transmute([]u8)string("{}"), &res)

	reset(&res)
	res_error(transmute([]u8)string("error"), &res)

	reset(&res)
	res_redirect("/gallery", &res)
}
assert_res_helper :: proc "contextless" (res: ^Response) {
	context = runtime.default_context()
	assert(res != nil)

	raw := cast(^runtime.Raw_Map)&res.headers
	assert(raw.allocator.procedure != nil)
}
// ENDREGION


res_text :: proc "contextless" (txt: string, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Text]
	res.body = transmute([]u8)txt
	res.status = status
}

res_blob :: proc(b: []u8, res: ^Response, type := Content_Type.Octet_Stream, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[type]
	res.body = b
	res.status = status
}

res_html :: proc(b: []u8, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Html]
	res.body = b
	res.status = status

}
res_json :: proc(b: []u8, res: ^Response, status := STATUS.OK) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[.Json]
	res.body = b
	res.status = status
}

res_error :: proc(
	b: []u8,
	res: ^Response,
	type := Content_Type.Text,
	status := STATUS.InternalServerError,
) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Content-Type"] = CONTENT_TYPE_MIME[type]
	res.body = b
	res.status = status

}
res_redirect :: proc(location: string, res: ^Response, status := STATUS.Found) {
	when ODIN_DEBUG {assert_res_helper(res)}

	res.headers["Location"] = location
	res.body = nil
	res.status = status
}
