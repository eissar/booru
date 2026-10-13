package media
import libwebp "../vendor/libwebp"
import "core:c"
import stbi "vendor:stb/image"

Decoded :: struct {
	pixels:        [^]u8,
	width, height: c.int,
	free_pixels:   proc "c" (_: rawptr),
}

decode_rgba :: proc(data: []u8) -> (img: Decoded) {
	if len(data) == 0 || len(data) > int(max(c.int)) {return}
	format := detect_format(data)
	p, n, w, h := raw_data(data), len(data), &img.width, &img.height
	if format == .WebP {
		img.free_pixels = libwebp.WebPFree
		img.pixels = libwebp.WebPDecodeRGBA(p, c.size_t(n), w, h)
	} else if format == .PNG || format == .JPEG || format == .GIF {
		img.free_pixels = stbi.image_free
		img.pixels = stbi.load_from_memory(p, c.int(n), w, h, nil, 4)
	}
	return
}

free_decoded :: proc(img: Decoded) {
	if img.pixels != nil {img.free_pixels(img.pixels)}
}
