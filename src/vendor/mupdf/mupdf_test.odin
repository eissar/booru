package mupdf

import "core:os"
import "core:path/filepath"
import "core:testing"

MINIMAL_PDF :: `%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] >> endobj
xref
0 4
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
trailer << /Size 4 /Root 1 0 R >>
startxref
186
%%EOF
`

@(test)
probe_and_render_minimal_pdf :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "mupdf_test_*", context.temp_allocator)
	testing.expect_value(t, dir_err, nil)
	defer os.remove_all(dir)

	pdf_path, join_err := filepath.join({dir, "sample.pdf"}, context.temp_allocator)
	testing.expect_value(t, join_err, nil)
	write_err := os.write_entire_file(pdf_path, transmute([]u8)string(MINIMAL_PDF))
	testing.expect_value(t, write_err, nil)

	pw, ph, probe_ok := probe_dimensions(pdf_path)
	testing.expect(t, probe_ok, "probe_dimensions succeeds")
	testing.expect_value(t, pw, 200)
	testing.expect_value(t, ph, 400)

	pixels, rw, rh, render_ok := render_first_page_rgba(pdf_path, 512)
	testing.expect(t, render_ok, "render_first_page_rgba succeeds")
	defer if pixels != nil {mupdf_free_pixels(pixels)}

	testing.expect_value(t, rw, 256)
	testing.expect_value(t, rh, 512)
	// First pixel should be opaque white (255, 255, 255, 255).
	testing.expect_value(t, pixels[0], u8(255))
	testing.expect_value(t, pixels[1], u8(255))
	testing.expect_value(t, pixels[2], u8(255))
	testing.expect_value(t, pixels[3], u8(255))
}
