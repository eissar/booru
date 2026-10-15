package thumbnail

import "core:bufio"
import "core:encoding/endian"
import "core:io"
import "core:mem"
import "core:net"

// Validate before sending HTTP headers and replace unsupported inputs in place.
// Returns the exact emitted length, including the RIFF prelude.
Prepare_Webp_X :: proc(files: []Thumb, p: ^Webp_Extended_Prefix) -> int {
	length := RIFF_X_SIZE
	canvas_width, canvas_height: u32
	for &t in files {
		width, height, frame_bytes, ok := webp_frame_info(t.bytes)
		if !ok {
			if t.width == 128 {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_128_WEBP
			} else {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_64_WEBP
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

// idk -> Stream_MipMaps
// thumbnails[slot] = thumbnail.Thumb{t_bytes, req_resolution, req_resolution}
Webp_X :: proc(
	files: []Thumb,
	p: ^Webp_Extended_Prefix,
	conn: ^net.TCP_Socket,
) -> (
	err: io.Error,
) {
	buffer: [4 * 1024]u8

	writer: bufio.Writer
	bufio.writer_init_with_buf(&writer, socket_writer(conn), buffer[:])
	out_stream := bufio.writer_to_writer(&writer)
	defer {
		if err == nil {
			err = bufio.writer_flush(&writer)
		}
	}

	return Write_Webp_X(files, p, out_stream)
}

// Shared encoder for socket output and in-memory tests.
Write_Webp_X :: proc(files: []Thumb, p: ^Webp_Extended_Prefix, out_stream: io.Writer) -> io.Error {
	// prelude
	io.write(out_stream, p.WEBP[:], nil) or_return
	io.write(out_stream, p.VP8X[:], nil) or_return
	io.write(out_stream, p.ANIM[:], nil) or_return


	for t in files {
		data := t.bytes // alias
		offset := 12 // skip source prelude


		// we loop over all chunks
		// we only want the VP8 chunk,
		// but for example with transparent thumbnails,
		// there is an optional ALPH header
		//
		// also technically there can be an arbitrary
		// amount of unknown chunks we are meant to
		// ignore per the spec
		for {
			if offset == len(data) {
				return .Unsupported // no VP8 chunk found
			}
			if offset > len(data) || len(data) - offset < 8 {
				return .Unknown
			}

			// riff files are a sequence of chunks; the chunk
			// header is always 8 bytes. fourcc & len
			f, l, ok := parse_chunk_header(data[offset:offset + 8])
			if !ok {return .Unknown}


			payload_start := offset + 8
			payload_end := payload_start + int(l)
			payload_chunk_end := payload_end + int(l % 2)
			if payload_chunk_end > len(data) {
				return .Unknown
			}

			if f == .VP8X {
				alpha_offset := 0
				alpha_bytes := 0
				next_offset := payload_end

				for {
					if next_offset == len(data) {
						return .Unsupported // no VP8 chunk found
					}
					if next_offset > len(data) || len(data) - next_offset < 8 {
						return .Unknown
					}

					cc, chunk_size, chunk_ok := parse_chunk_header(
						data[next_offset:next_offset + 8],
					)
					if !chunk_ok {return .Unknown}

					chunk_start := next_offset + 8
					chunk_end := chunk_start + int(chunk_size)
					padded_end := chunk_end + int(chunk_size % 2)
					if padded_end > len(data) {
						return .Unknown
					}

					if cc == .ALPH {
						alpha_offset = next_offset
						alpha_bytes = padded_end - next_offset
					}

					if cc == .VP8L || cc == .ANIM || cc == .ANMF {
						return .Unsupported
					}

					if cc == .VP8 {
						payload := data[chunk_start:chunk_end]
						if len(payload) < 10 {return .Unknown}

						width, width_ok := endian.get_u16(payload[6:8], .Little)
						height, height_ok := endian.get_u16(payload[8:10], .Little)
						if !width_ok || !height_ok || width == 0 || height == 0 {
							return .Unknown
						}

						width_minus_one := transmute([4]u8)u32le(width - 1)
						height_minus_one := transmute([4]u8)u32le(height - 1)

						// ANMF includes the optional ALPH chunk and VP8 chunk.
						frame_size := u32le(chunk_size + chunk_size % 2 + 24 + u32(alpha_bytes))
						io.write(out_stream, ANMF_CC[:], nil) or_return
						io.write(out_stream, mem.any_to_bytes(frame_size), nil) or_return

						zeroed_offset: [6]u8
						io.write(out_stream, zeroed_offset[:], nil) or_return
						io.write(out_stream, width_minus_one[:3], nil) or_return
						io.write(out_stream, height_minus_one[:3], nil) or_return

						duration := transmute([4]u8)u32le(30)
						flags := transmute(u8)bit_set[ANMF_Flags;u8] {
							.blend_method,
							.disposal_method,
						}
						duration[3] = flags
						io.write(out_stream, duration[:], nil) or_return

						if alpha_bytes != 0 {
							io.write(
								out_stream,
								data[alpha_offset:alpha_offset + alpha_bytes],
								nil,
							) or_return
						}

						io.write(out_stream, data[next_offset:padded_end], nil) or_return
						break
					}

					next_offset = padded_end
				}

				break
			}

			if f == .VP8L {
				return .Unsupported
			}


			if f == .VP8 {
				payload := data[payload_start:payload_start + int(l)]
				if len(payload) < 10 {return .Unknown}

				// VP8 dimensions are u16 little-endian fields here.
				width, width_ok := endian.get_u16(payload[6:8], .Little)
				height, height_ok := endian.get_u16(payload[8:10], .Little)
				if !width_ok || !height_ok || width == 0 || height == 0 {
					return .Unknown
				}

				width_minus_one := transmute([4]u8)u32le(width - 1)
				height_minus_one := transmute([4]u8)u32le(height - 1)

				// ANMF ChunkHeader
				frame_size := u32le(l + l % 2 + 24)
				io.write(out_stream, ANMF_CC[:], nil) or_return
				io.write(out_stream, mem.any_to_bytes(frame_size), nil) or_return

				// frame x(u24)/y(u24)
				zeroed_offset: [6]u8
				io.write(out_stream, zeroed_offset[:], nil) or_return

				// frame width-minus-one / height-minus-one, both u24
				io.write(out_stream, width_minus_one[:3], nil) or_return
				io.write(out_stream, height_minus_one[:3], nil) or_return

				// duration (u24 milliseconds), followed by ANMF flags
				duration := transmute([4]u8)u32le(30)
				flags := transmute(u8)bit_set[ANMF_Flags;u8]{.blend_method, .disposal_method}
				duration[3] = flags
				io.write(out_stream, duration[:], nil) or_return

				io.write(out_stream, data[offset:payload_chunk_end], nil) or_return
				break
			}

			offset = payload_chunk_end
		}

	}
	return nil
}
