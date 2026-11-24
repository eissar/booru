#+build linux amd64
package media

import mupdf "../vendor/mupdf"
import "core:c"
import "core:io"

// mupdf is vendored for Linux amd64 only; pdf_unsupported.odin covers other targets.

probe_pdf_dimensions :: proc(path: string) -> (width, height: c.int, ok: bool) {
	return mupdf.probe_dimensions(path)
}

decode_pdf_first_page :: proc(
	stream: io.Stream,
	max_pixels: i64,
) -> (
	frame: Decoded_Frame,
	err: Decode_Error,
) {
	pixels, w, h, ok := mupdf.render_first_page_rgba(stream, 512)
	if !ok {return nil, .Failed}
	if max_pixels > 0 && i64(w) * i64(h) > max_pixels {
		mupdf.mupdf_free_pixels(pixels)
		return nil, .Too_Large
	}
	return Decoded_ARGB {
			pixels = pixels,
			width = w,
			height = h,
			free_pixels = mupdf.mupdf_free_pixels,
		},
		.None
}
