package thumbnail

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:io"
import "core:net"
import "core:testing"
import "core:thread"

import libwebp "../vendor/libwebp"
import "../vendor/webpinfo"

@(test)
stream_webp_socket_batches :: proc(t: ^testing.T) {
	pixels := [6]u8{255, 0, 0, 0, 255, 0}
	encoded: ^u8
	size := libwebp.WebPEncodeRGB(&pixels[0], 2, 1, 6, 75, &encoded)
	if !testing.expect(t, size > 0 && encoded != nil) {return}
	defer libwebp.WebPFree(encoded)
	plain := (cast([^]u8)encoded)[:int(size)]

	// Extended source with odd-sized metadata and an odd-sized ALPH payload.
	// Both source chunks already have their required padding byte.
	alpha := make([]u8, len(plain) + 18 + 10 + 12)
	defer delete(alpha)
	copy(alpha[:12], plain[:12])
	copy(alpha[12:16], transmute([]u8)string("VP8X"))
	endian.put_u32(alpha[16:20], .Little, 10)
	alpha[20] = transmute(u8)bit_set[WEBP_Flags;u8]{.Alpha}
	alpha[24] = 1 // Canvas width minus one, height minus one stays zero.
	copy(alpha[30:34], transmute([]u8)string("JUNK"))
	endian.put_u32(alpha[34:38], .Little, 1)
	alpha[38] = 7
	copy(alpha[40:44], transmute([]u8)string("ALPH"))
	endian.put_u32(alpha[44:48], .Little, 3)
	alpha[48] = 0 // Uncompressed alpha.
	alpha[49] = 128
	alpha[50] = 64
	copy(alpha[52:], plain[12:])
	endian.put_u32(alpha[4:8], .Little, u32(len(alpha) - 8))

	plain_thumb := Thumb {
		bytes  = plain,
		width  = 2,
		height = 1,
	}
	alpha_thumb := Thumb {
		bytes  = alpha,
		width  = 2,
		height = 1,
	}
	batches := [?][]Thumb {
		{plain_thumb},
		{alpha_thumb},
		{plain_thumb, alpha_thumb, plain_thumb},
		{alpha_thumb, {bytes = []u8{1, 2, 3}, width = 64}},
	}
	for batch, batch_index in batches {
		prefix: Webp_Extended_Prefix
		length := Prepare_Webp_X(batch, &prefix)
		canvas_width, _ := endian.get_u32(prefix.VP8X[12:16], .Little)
		// Width occupies the low three bytes; the next height byte is zero here.
		testing.expect(t, canvas_width > 0, "canvas populated")

		listener, listen_err := net.listen_tcp(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 0})
		if !testing.expect(t, listen_err == nil) {return}
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if !testing.expect(t, endpoint_err == nil) {
			net.close(listener)
			return
		}
		state := struct {
			listener: net.TCP_Socket,
			files:    []Thumb,
			prefix:   Webp_Extended_Prefix,
			err:      io.Error,
		} {
			listener = listener,
			files    = batch,
			prefix   = prefix,
		}
		worker := thread.create_and_start_with_data(&state, proc(raw: rawptr) {
			defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
			state := cast(^struct {
				listener: net.TCP_Socket,
				files:    []Thumb,
				prefix:   Webp_Extended_Prefix,
				err:      io.Error,
			})raw
			conn, _, err := net.accept_tcp(state.listener)
			if err != nil {
				state.err = .Unknown
				return
			}
			defer net.close(conn)
			state.err = Webp_X(state.files, &state.prefix, &conn)
		})
		conn, connect_err := net.dial_tcp(endpoint)
		if !testing.expect(t, connect_err == nil) {
			// Close before joining to wake accept on Windows.
			_ = net.shutdown(listener, .Both)
			net.close(listener)
			thread.join(worker)
			thread.destroy(worker)
			return
		}
		output := make([dynamic]u8)
		buffer: [4096]u8
		for {
			n, recv_err := net.recv_tcp(conn, buffer[:])
			if n > 0 {append(&output, ..buffer[:n])}
			if recv_err != nil || n == 0 {break}
		}
		net.close(conn)
		thread.join(worker)
		thread.destroy(worker)
		net.close(listener)
		testing.expect(t, state.err == nil, "socket writer succeeded")
		testing.expect(t, len(output) == length, "declared HTTP length matches socket bytes")
		testing.expect(
			t,
			bytes.count(output[:], transmute([]u8)string("ANMF")) == len(batch),
			"one frame per slot",
		)
		if batch_index != 0 {
			testing.expect(
				t,
				bytes.contains(output[:], alpha[40:52]),
				"ALPH and existing pad retained",
			)
			testing.expect(t, !bytes.contains(output[:], alpha[30:40]), "unknown metadata skipped")
		}

		status := webpinfo.validate(raw_data(output[:]), len(output))
		testing.expect(t, status == .OK, fmt.tprintf("webpinfo: validation status=%v", status))
		delete(output)
	}
}
