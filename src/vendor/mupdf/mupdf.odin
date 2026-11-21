package mupdf

import "core:c"
import "core:strings"

when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import mupdf {"linux-amd64/libmupdf-shim.a", "linux-amd64/libmupdf.a", "linux-amd64/libmupdf-third.a", "system:m", "system:pthread"}
} else {
	#panic("mupdf supports Linux amd64 only")
}

@(default_calling_convention = "c")
foreign mupdf {
	mupdf_probe_dimensions :: proc(path: cstring, out_w: ^c.int, out_h: ^c.int) -> c.int ---
	mupdf_render_first_page_rgba :: proc(path: cstring, max_edge: c.int, out_w: ^c.int, out_h: ^c.int, out_pixels: ^[^]u8) -> c.int ---
	mupdf_free_pixels :: proc(p: rawptr) ---
}

probe_dimensions :: proc(path: string) -> (width, height: c.int, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if mupdf_probe_dimensions(cpath, &width, &height) == 0 {
		return 0, 0, false
	}
	return width, height, true
}

render_first_page_rgba :: proc(
	path: string,
	max_edge: c.int = 512,
) -> (
	pixels: [^]u8,
	width, height: c.int,
	ok: bool,
) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if mupdf_render_first_page_rgba(cpath, max_edge, &width, &height, &pixels) == 0 {
		return nil, 0, 0, false
	}
	return pixels, width, height, true
}
