package thumbnail

import "base:runtime"
import "core:bufio"
import "core:bytes"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:os"


Thumb :: struct {
	bytes:  []u8, // Complete standalone WebP file; backing memory owned by caller.
	width:  u16le, // Actual thumbnail dimensions, not minus-one encoded values.
	height: u16le,
}

NOT_FOUND_64_WEBP :: #load("../../static/not_found_64.webp")
NOT_FOUND_128_WEBP :: #load("../../static/not_found_128.webp")
UNSUPPORTED_FILETYPE_64_WEBP :: #load("../../static/unsupported_filetype_64.webp")
UNSUPPORTED_FILETYPE_128_WEBP :: #load("../../static/unsupported_filetype_128.webp")
new_not_found_thumb :: proc(resolution: u16le) -> Thumb {
	if resolution == 128 {
		return Thumb{transmute([]u8)NOT_FOUND_128_WEBP, 128, 128}
	}
	return Thumb{transmute([]u8)NOT_FOUND_64_WEBP, 64, 64}
}


// attempt to implement
// RFC9649 https://www.rfc-editor.org/info/rfc9649/
// contextless specifiers (e.g., 2.7.1.1) reference sections of
// aforementioned rfc.

FourCC :: enum {
	Unknown,
	RIFF,
	WEBP,
	VP8,
	VP8X,
	VP8L,
	ALPH,
	ANIM,
	ANMF,
}

// 8 bytes fourCC, then size (little-endian, excludes padding)
ChunkHeader :: struct {
	fourcc: FourCC,
	size:   u32,
}

Chunk :: struct {
	using header: ChunkHeader,
	payload:      []u8,
	// HACK: fix this later
	size_plus_24: u32le,
}


ANMF_Flags :: enum u8 {
	disposal_method = 0,
	blend_method    = 1,
	_               = 2,
	_               = 3,
	_               = 4,
	_               = 5,
	_               = 6,
	_               = 7,
}
RIFF_CC := [4]u8{'R', 'I', 'F', 'F'}
WEBP_CC := [4]u8{'W', 'E', 'B', 'P'}
VP8_CC := [4]u8{'V', 'P', '8', ' '}
VP8X_CC := [4]u8{'V', 'P', '8', 'X'}
VP8L_CC := [4]u8{'V', 'P', '8', 'L'}
ANIM_CC := [4]u8{'A', 'N', 'I', 'M'}
ANMF_CC := [4]u8{'A', 'N', 'M', 'F'}


main :: proc() {
	// ANMF

	d, read_err := os.read_entire_file_from_path(
		"/home/eissar/code/lfs-booru-odin/src/thumbnail/t-metadata.json",
		context.temp_allocator,
	)
	if read_err != nil {fmt.println("couldn't read"); os.exit(1)}

	j, err := json.parse(d)
	if err != nil {fmt.println("couldn't parse"); os.exit(1)}

	chunks: [dynamic]Chunk
	// thumbs: [dynamic]Thumb
	for item in j.(json.Array) {
		obj := item.(json.Object)
		path := fmt.aprintf(
			"%v%v",
			"/home/eissar/code/lfs-booru-odin/src/thumbnail/",
			obj["thumb"],
		)
		d, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {fmt.println("could not read", path); os.exit(1)}

		chunk: Chunk
		parse_chunk(d[12:], &chunk)

		if chunk.fourcc == .VP8L {
			fmt.println("Unimplemented error: vp8L")
			os.exit(1)
		}
		if chunk.fourcc == .VP8 {
			append_elem(&chunks, chunk)
			continue
		}
	}

	// newThumbnailAtlas(thumbs[:])
}

// this copies a bunch of data
// passing riff_size - code smell
thumbnail_prefix :: proc(prefix: ^Webp_Extended_Prefix, riff_size: u32le) {
	// WEBP

	copy(prefix.WEBP[0:4], RIFF_CC[:])
	copy(prefix.WEBP[4:8], mem.slice_to_bytes([]u32le{riff_size})) // The size of the file in bytes, starting at offset 8.
	copy(prefix.WEBP[8:12], WEBP_CC[:])

	// VP8X
	webp_byte := transmute(u8)bit_set[WEBP_Flags;u8]{.Animated, .Alpha}
	copy(prefix.VP8X[0:4], VP8X_CC[:])
	copy(prefix.VP8X[4:8], mem.slice_to_bytes([]u32le{10}))
	// webp_byte: 1
	//  0, 0, 0 : 3 reserved
	// Canvas dimensions are populated by Thumbnail_MipMap.
	prefix.VP8X[8] = webp_byte

	// optional iccp chunk

	// REGION: ANIM chunk 8 (header) + 6
	anim_size_bytes := transmute([4]byte)u32le(6)
	copy(prefix.ANIM[0:4], ANIM_CC[:])
	copy(prefix.ANIM[4:8], anim_size_bytes[:])
	// 0, 0, 0, 0: bg color 32 bits
	// 0, 0      : loop count 16 bits
	copy(prefix.ANIM[8:14], mem.slice_to_bytes([]u8{0, 0, 0, 0, 0, 0}))
	// ENDREGION: ANIM
}

// creates multiple []u8 using provided allocator and returns a slice to them
Thumbnail_MipMap :: proc(streams: []Thumb, alloc: runtime.Allocator) -> [][]u8 {
	vec := make([][]u8, 3 + 9 * len(streams), alloc)

	length_of_thumbs := 0
	for &t in streams {
		if parse_fourcc(t.bytes[12:]) != .VP8 {
			if t.width == 128 {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_128_WEBP
			} else {
				t.bytes = transmute([]u8)UNSUPPORTED_FILETYPE_64_WEBP
			}
		}
		// Assume VP8: key-frame dimensions are little-endian u14 values at these offsets.
		t.width = (u16le(t.bytes[26]) | u16le(t.bytes[27]) << 8) & 0x3fff
		t.height = (u16le(t.bytes[28]) | u16le(t.bytes[29]) << 8) & 0x3fff
		// Count only the image chunks that will go inside ANMF, including
		// their chunk headers and existing padding. Skip the 12-byte RIFF
		// prelude and, for extended WebP, the 18-byte VP8X chunk as well.
		// Assumes generated files contain only VP8, or VP8X + ALPH + VP8;
		// any additional metadata chunks would need to be excluded separately.
		offset := 12
		if parse_fourcc(t.bytes[offset:]) == .VP8X {
			offset += 18
		}
		length_of_thumbs += len(t.bytes) - offset
	}

	prefix := new(Webp_Extended_Prefix, alloc)
	riff_size := compute_extended_riff_size(RIFF_X_SIZE, len(streams), length_of_thumbs)
	thumbnail_prefix(prefix, riff_size)


	// chunks: [dynamic]Chunk
	chunks := make([dynamic]Chunk, alloc)
	resize(&chunks, len(streams))

	chunk_idx := 0
	for s in streams {
		c := &chunks[chunk_idx]
		parse_chunk(s.bytes[12:], c)
		chunk_idx += 1
	}

	dims := new([2][]u8, alloc)

	t := streams[0]
	edge := u32(max(t.width, t.height))
	sizes := [2]u32{edge, edge}
	for i in 0 ..< 2 {
		encoded := transmute([4]u8)u32le(sizes[i] - 1)
		dims[i] = make([]u8, 3, alloc)
		copy(dims[i], encoded[:3])
	}

	copy(prefix.VP8X[12:15], dims[0])
	copy(prefix.VP8X[15:18], dims[1])

	Vectorized_Webp_Extended(chunks[:], &vec, prefix, dims, alloc)
	return vec
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
			chunk_end := payload_end + int(l % 2)
			if chunk_end > len(data) {
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

				io.write(out_stream, data[offset:chunk_end], nil) or_return
				break
			}

			offset = chunk_end
		}

	}
	return nil
}


@(private = "file")
socket_writer_proc :: proc(
	data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	socket := (^net.TCP_Socket)(data)

	#partial switch mode {
	case .Write:
		bw, send_err := net.send_tcp(socket^, p)
		if send_err != nil {
			return i64(bw), .Unknown
		}
		if bw != len(p) {
			return i64(bw), .Short_Write
		}
		return i64(bw), nil

	case .Flush:
		// This adapter has no buffer of its own.
		return 0, nil

	case .Query:
		return io.query_utility({.Write, .Flush, .Query})
	}

	return 0, .Unsupported
}

socket_writer :: proc(socket: ^net.TCP_Socket) -> io.Writer {
	return {procedure = socket_writer_proc, data = socket}
}
