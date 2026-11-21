package thumbnail

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import "../library"
import "../media"
import libwebp "../vendor/libwebp"

@(private = "file")
MINIMAL_PDF :: `%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] /Contents 4 0 R >> endobj
4 0 obj << /Length 26 >>
stream
0 0 0 rg 10 10 50 50 re f
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000202 00000 n 
trailer << /Size 5 /Root 1 0 R >>
startxref
277
%%EOF
`

@(test)
pdf_probe_decode_and_thumbnail :: proc(t: ^testing.T) {
	root, tmp_err := os.make_directory_temp("", "booru-pdf-thumb-*", context.allocator)
	if !testing.expect(t, tmp_err == nil, "create temp dir") {return}
	defer delete(root)
	defer os.remove_all(root)

	images_dir := fmt.tprintf("%s/images", root)
	if !testing.expect(t, os.make_directory(images_dir) == nil, "create images dir") {return}

	pdf_path := fmt.tprintf("%s/1.pdf", images_dir)
	if !testing.expect(
		t,
		os.write_entire_file(pdf_path, transmute([]u8)string(MINIMAL_PDF)) == nil,
		"write pdf",
	) {
		return
	}

	w, h, probe_ok := media.probe_dimensions(nil, .PDF, pdf_path)
	testing.expect(t, probe_ok, "probe_dimensions succeeds for pdf")
	testing.expect_value(t, w, 200)
	testing.expect_value(t, h, 400)

	_, _, no_path_ok := media.probe_dimensions(nil, .PDF)
	testing.expect(t, !no_path_ok, "probe_dimensions without path fails for pdf")

	frame, decode_err := media.decode_frame(pdf_path, MAX_THUMBNAIL_SOURCE_PIXELS)
	testing.expect_value(t, decode_err, media.Decode_Error.None)
	if argb, ok := frame.(media.Decoded_ARGB); testing.expect(t, ok, "decoded frame is ARGB") {
		testing.expect_value(t, argb.width, 256)
		testing.expect_value(t, argb.height, 512)
	}
	media.free_decoded(&frame)

	s := library.State {
		library_path = root,
	}
	img := library.Image {
		id           = 1,
		oid          = "pdfoid",
		ext          = "pdf",
		content_type = "application/pdf",
	}
	generated, failed := generate_image_thumbnails(s, img, expected_resolutions(img.content_type))
	testing.expect_value(t, generated, 3)
	testing.expect_value(t, failed, 0)
	testing.expect(t, os.exists(fmt.tprintf("%s/thumbnails/64/pdfoid.webp", root)), "64px webp")
	testing.expect(t, os.exists(fmt.tprintf("%s/thumbnails/128/pdfoid.webp", root)), "128px webp")

	max_bytes, max_err := os.read_entire_file(
		fmt.tprintf("%s/thumbnails/max/pdfoid.webp", root),
		context.temp_allocator,
	)
	if testing.expect(t, max_err == nil, "read max webp") {
		mw, mh: c.int
		testing.expect(
			t,
			libwebp.WebPGetInfo(raw_data(max_bytes), c.size_t(len(max_bytes)), &mw, &mh) != 0,
			"valid max webp",
		)
		testing.expect_value(t, mw, 256)
		testing.expect_value(t, mh, 512)
	}
}
