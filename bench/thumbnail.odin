package bench

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "../src/thumbnail"
import libwebp "../src/vendor/libwebp"

@(test)
resize_half :: proc(t: ^testing.T) {
	iterations :: 100
	paths := [?]string {
		"test/fixture/library/thumbnails/0aed5445db349824f16987bba714e513211cd8d0ae827f9459b157b763adfdb5.webp",
		"test/fixture/library/thumbnails/9c2efc8f0c7cde25eb24ee5a589b919731e6a125793c05de070910d6ac2a5f8c.webp",
		"test/fixture/library/thumbnails/4ef24abe584d4358473279073cc0a35150802774bb97f5fea35e24d661668ce6.webp",
	}
	file, err := os.open("/dev/null", os.O_WRONLY)
	if !testing.expect(t, err == nil, "open output") {return}
	defer os.close(file)

	for path in paths {
		data, read_err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, read_err == nil, "read fixture") {return}

		start := time.tick_now()
		for _ in 0 ..< iterations {
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
			if y == nil {
				delete(data)
				testing.expect(t, false, "decode fixture")
				return
			}
			pic := libwebp.WebPPicture {
				width     = w,
				height    = h,
				y         = y,
				u         = u,
				v         = v,
				y_stride  = stride,
				uv_stride = uv_stride,
			}
			ok := thumbnail.rescale_half(&pic, file)
			libwebp.WebPPictureFree(&pic)
			libwebp.WebPFree(y)
			if !ok {
				delete(data)
				testing.expect(t, false, "rescale fixture")
				return
			}
		}
		elapsed := time.tick_since(start)
		delete(data)
		fmt.printfln(
			"resize_half/%s: %.2f us/op (%d iterations; decode, resize, encode to /dev/null, cleanup)",
			path,
			time.duration_seconds(elapsed) * 1e6 / f64(iterations),
			iterations,
		)
	}
}
