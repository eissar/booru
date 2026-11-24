package mupdf

import "base:runtime"
import "core:c"
import "core:io"
import "core:strings"

when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import mupdf {"linux-amd64/libmupdf-shim.a", "linux-amd64/libmupdf.a", "linux-amd64/libmupdf-third.a", "system:m", "system:pthread"}
} else {
	#panic("mupdf supports Linux amd64 only")
}

@(default_calling_convention = "c")
foreign mupdf {
	mupdf_probe_dimensions :: proc(path: cstring, out_w: ^c.int, out_h: ^c.int) -> c.int ---
	mupdf_render_first_page_rgba :: proc(opaque: rawptr, read_at: proc "c" (opaque: rawptr, buf: [^]u8, n: c.size_t, offset: i64) -> i64, size: i64, max_edge: c.int, out_w: ^c.int, out_h: ^c.int, out_pixels: ^[^]u8) -> c.int ---
	mupdf_free_pixels :: proc(p: rawptr) ---
}

probe_dimensions :: proc(path: string) -> (width, height: c.int, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if mupdf_probe_dimensions(cpath, &width, &height) == 0 {
		return 0, 0, false
	}
	return width, height, true
}

// Renders the first page of the document read from `stream` (Read_At + Size).
render_first_page_rgba :: proc(
	stream: io.Stream,
	max_edge: c.int = 512,
) -> (
	pixels: [^]u8,
	width, height: c.int,
	ok: bool,
) {
	size, size_err := io.size(stream)
	if size_err != nil {return nil, 0, 0, false}
	s := stream
	rc := mupdf_render_first_page_rgba(
		&s,
		stream_read_at,
		size,
		max_edge,
		&width,
		&height,
		&pixels,
	)
	if rc == 0 {
		return nil, 0, 0, false
	}
	return pixels, width, height, true
}

@(private)
stream_read_at :: proc "c" (opaque: rawptr, buf: [^]u8, n: c.size_t, offset: i64) -> i64 {
	context = runtime.default_context()
	got, err := io.read_at((^io.Stream)(opaque)^, buf[:n], offset)
	if got == 0 && err != nil && err != .EOF {return -1}
	return i64(got)
}
