package webpx

import thumbnail "../"
import "core:encoding/endian"

// Validate before sending HTTP headers and replace unsupported inputs in place.
// Returns the exact emitted length, including the RIFF prelude.
Prepare_Webp_X :: proc(files: []thumbnail.Thumb, p: ^Webp_Extended_Prefix) -> int {
	length := RIFF_X_SIZE
	canvas_width, canvas_height: u32
	for &t in files {
		width, height, frame_bytes, ok := webp_frame_info(t.bytes)
		if !ok {
			if t.width == 128 {
				t.bytes = transmute([]u8)thumbnail.UNSUPPORTED_FILETYPE_128_WEBP
			} else {
				t.bytes = transmute([]u8)thumbnail.UNSUPPORTED_FILETYPE_64_WEBP
			}
			width, height, frame_bytes, ok = webp_frame_info(t.bytes)
			assert(ok, "unsupported-thumbnail fixture must contain a valid VP8 frame")
		}
		canvas_width = max(canvas_width, width)
		canvas_height = max(canvas_height, height)
		length += 24 + frame_bytes
	}
	thumbnail_prefix(p, u32le(length - 8))
	if len(files) > 0 {
		width := transmute([4]u8)u32le(canvas_width - 1)
		height := transmute([4]u8)u32le(canvas_height - 1)
		copy(p.VP8X[12:15], width[:3])
		copy(p.VP8X[15:18], height[:3])
	}
	return length
}

@(private = "file")
webp_frame_info :: proc(data: []u8) -> (width, height: u32, frame_bytes: int, ok: bool) {
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WEBP" {
		return
	}
	offset := 12
	extended := false
	alpha_bytes := 0
	for offset < len(data) {
		if len(data) - offset < 8 {return}
		cc, size, header_ok := parse_chunk_header(data[offset:offset + 8])
		if !header_ok {return}
		start := offset + 8
		end := start + int(size)
		padded_end := end + int(size % 2)
		if padded_end > len(data) {return}
		if cc == .VP8X {
			extended = true
		}
		if cc == .ALPH && extended {
			alpha_bytes = padded_end - offset
		}
		if cc == .VP8L || cc == .ANIM || cc == .ANMF {return}
		if cc == .VP8 {
			if size < 10 {return}
			w, w_ok := endian.get_u16(data[start + 6:start + 8], .Little)
			h, h_ok := endian.get_u16(data[start + 8:start + 10], .Little)
			if !w_ok || !h_ok || w == 0 || h == 0 {return}
			return u32(w), u32(h), alpha_bytes + padded_end - offset, true
		}
		offset = padded_end
	}
	return
}
