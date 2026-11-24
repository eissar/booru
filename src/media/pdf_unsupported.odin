#+build !linux, !amd64
package media

import "core:c"
import "core:io"

// No mupdf build for this target: PDFs are stored but not probed or thumbnailed.

probe_pdf_dimensions :: proc(path: string) -> (width, height: c.int, ok: bool) {
	return 0, 0, false
}

decode_pdf_first_page :: proc(
	stream: io.Stream,
	max_pixels: i64,
) -> (
	frame: Decoded_Frame,
	err: Decode_Error,
) {
	return nil, .Unsupported
}
