package ffmpeg

import "core:c"
import "core:strings"

// Decoded first video frame. Planes point into `frame`; valid until close.
@(private)
First_Frame :: struct {
	frame:         ^AVFrame,
	width, height: c.int,
	pix_fmt:       c.int, // AV_PIX_FMT_*; callers must validate before using the planes.
	y, u, v:       [^]u8,
	y_stride:      c.int,
	uv_stride:     c.int,
}

@(private)
first_frame_close :: proc(ff: ^First_Frame) {
	if ff.frame != nil {av_frame_free(&ff.frame)}
	ff^ = {}
}

// Decodes the first video frame of `path` without seeking.
first_frame :: proc(path: string) -> (ff: First_Frame, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	fmt_ctx: ^AVFormatContext
	if avformat_open_input(&fmt_ctx, cpath, nil, nil) < 0 {return}
	defer avformat_close_input(&fmt_ctx)
	if avformat_find_stream_info(fmt_ctx, nil) < 0 {return}

	codec: ^AVCodec
	idx := av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
	if idx < 0 || codec == nil {return}

	par := fmt_ctx.streams[idx].codecpar
	cctx := avcodec_alloc_context3(codec)
	if cctx == nil {return}
	defer avcodec_free_context(&cctx)
	if avcodec_parameters_to_context(cctx, par) < 0 {return}
	if avcodec_open2(cctx, codec, nil) < 0 {return}

	pkt := av_packet_alloc()
	if pkt == nil {return}
	defer av_packet_free(&pkt)
	frame := av_frame_alloc()
	if frame == nil {return}
	defer if !ok {av_frame_free(&frame)}

	got := false
	read_loop: for av_read_frame(fmt_ctx, pkt) >= 0 {
		if pkt.stream_index != idx {
			av_packet_unref(pkt)
			continue
		}
		rc := avcodec_send_packet(cctx, pkt)
		av_packet_unref(pkt)
		if rc < 0 && rc != AVERROR_EAGAIN {break}
		if avcodec_receive_frame(cctx, frame) >= 0 {got = true; break read_loop}
	}
	if !got {
		// Flush the decoder (delayed frames from B-frame reordering).
		avcodec_send_packet(cctx, nil)
		got = avcodec_receive_frame(cctx, frame) >= 0
	}
	if !got {return}

	ff = First_Frame {
		frame     = frame,
		width     = frame.width,
		height    = frame.height,
		pix_fmt   = frame.format,
		y         = frame.data[0],
		u         = frame.data[1],
		v         = frame.data[2],
		y_stride  = frame.linesize[0],
		uv_stride = frame.linesize[1],
	}
	return ff, true
}
