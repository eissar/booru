package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../library"
import libwebp "../vendor/libwebp"

FIXTURE_LIBRARY :: "test/fixture/library"

when ODIN_OS == .Windows {
	NULL_DEVICE :: "NUL"
} else {
	NULL_DEVICE :: "/dev/null"
}

@(test)
rescale_fixtures :: proc(t: ^testing.T) {
	state := library.State {
		library_path = FIXTURE_LIBRARY,
	}
	file, err := os.open(NULL_DEVICE, os.O_WRONLY)
	if !testing.expect(t, err == nil, "open output") {return}
	defer os.close(file)

	oids := [?]string {
		"0aed5445db349824f16987bba714e513211cd8d0ae827f9459b157b763adfdb5",
		"9c2efc8f0c7cde25eb24ee5a589b919731e6a125793c05de070910d6ac2a5f8c",
		"4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6",
	}
	for oid in oids {
		data, read_err := os.read_entire_file(
			fmt.tprintf("%s/thumbnails/%s.webp", state.library_path, oid),
			context.temp_allocator,
		)
		if !testing.expectf(t, read_err == nil, "read %s", oid) {continue}

		w, h, stride, uv_stride: c.int
		u, v: ^u8
		y := libwebp.WebPDecodeYUV(
			raw_data(data),
			c.size_t(len(data)),
			&w,
			&h,
			&u,
			&v,
			&stride,
			&uv_stride,
		)
		if !testing.expectf(t, y != nil, "decode %s", oid) {continue}
		defer libwebp.WebPFree(y)

		pic := libwebp.WebPPicture {
			width     = w,
			height    = h,
			y         = y,
			u         = u,
			v         = v,
			y_stride  = stride,
			uv_stride = uv_stride,
		}
		defer libwebp.WebPPictureFree(&pic)
		testing.expectf(t, libwebp.rescale(&pic, file, 48), "rescale %s", oid)
		testing.expect(t, max(pic.width, pic.height) == 48, "48px longest edge")
	}
}
