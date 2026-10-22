// Minimal decode-only bindings to FFmpeg (libavformat/libavcodec/libavutil) for
// first-frame extraction. No encoders, no libswscale: the decoded YUV planes are
// handed to libwebp.
//
// Licensing: only decoding is used, so link against an LGPL build and do not
// enable GPL/nonfree components. Encoders are the strictly-licensed part.
//
// Structs are opaque; fields are read through the offsets below, verified
// against the FFmpeg 7.1 headers (libavcodec 61 / libavformat 61 / libavutil 59).
// The #asserts only check this file against itself: after an FFmpeg major bump,
// regenerate the offsets with offsetof() in C.
package ffmpeg

import "core:c"
import "core:strings"

foreign import avformat "system:avformat"
foreign import avcodec "system:avcodec"
foreign import avutil "system:avutil"

AVFormatContext :: struct {}
AVCodecContext :: struct {}
AVCodec :: struct {}
AVDictionary :: struct {}
AVStream :: struct {}
AVCodecParameters :: struct {}
AVPacket :: struct {}
AVFrame :: struct {}

AVMEDIA_TYPE_VIDEO :: 0
AV_PIX_FMT_YUV420P :: 0
AV_PIX_FMT_YUVJ420P :: 12
AV_NOPTS_VALUE :: i64(-0x8000000000000000)
AV_TIME_BASE :: 1000000
AVERROR_EOF :: -541478725 // FFERRTAG('E','O','F',' ')
AVERROR_EAGAIN :: -11 // AVERROR(EAGAIN) on Linux
AVDISCARD_NONKEY :: 32

// Field offsets (x86_64 / aarch64 LP64, FFmpeg 7.1).
OFF_FMT_NB_STREAMS :: 44
OFF_FMT_STREAMS :: 48
OFF_FMT_DURATION :: 104
OFF_STREAM_INDEX :: 8
OFF_STREAM_CODECPAR :: 16
OFF_PAR_CODEC_TYPE :: 0
OFF_PAR_FORMAT :: 44
OFF_PAR_WIDTH :: 72
OFF_PAR_HEIGHT :: 76
OFF_PKT_STREAM_INDEX :: 36
OFF_FRAME_DATA :: 0
OFF_FRAME_LINESIZE :: 64
OFF_FRAME_WIDTH :: 104
OFF_FRAME_HEIGHT :: 108
OFF_FRAME_FORMAT :: 116

@(private)
field :: #force_inline proc "contextless" ($T: typeid, p: rawptr, off: uintptr) -> T {
	return (^T)(uintptr(p) + off)^
}

@(default_calling_convention = "c")
foreign avformat {
	avformat_open_input :: proc(ps: ^^AVFormatContext, url: cstring, fmt: rawptr, options: ^^AVDictionary) -> c.int ---
	avformat_find_stream_info :: proc(ic: ^AVFormatContext, options: ^^AVDictionary) -> c.int ---
	avformat_close_input :: proc(s: ^^AVFormatContext) ---
	av_find_best_stream :: proc(ic: ^AVFormatContext, type: c.int, wanted: c.int, related: c.int, decoder_ret: ^^AVCodec, flags: c.int) -> c.int ---
	av_read_frame :: proc(s: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
	av_seek_frame :: proc(s: ^AVFormatContext, stream_index: c.int, timestamp: i64, flags: c.int) -> c.int ---
}

@(default_calling_convention = "c")
foreign avcodec {
	avcodec_alloc_context3 :: proc(codec: ^AVCodec) -> ^AVCodecContext ---
	avcodec_free_context :: proc(avctx: ^^AVCodecContext) ---
	avcodec_parameters_to_context :: proc(codec: ^AVCodecContext, par: ^AVCodecParameters) -> c.int ---
	avcodec_open2 :: proc(avctx: ^AVCodecContext, codec: ^AVCodec, options: ^^AVDictionary) -> c.int ---
	avcodec_send_packet :: proc(avctx: ^AVCodecContext, avpkt: ^AVPacket) -> c.int ---
	avcodec_receive_frame :: proc(avctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---
	av_packet_alloc :: proc() -> ^AVPacket ---
	av_packet_free :: proc(pkt: ^^AVPacket) ---
	av_packet_unref :: proc(pkt: ^AVPacket) ---
}

@(default_calling_convention = "c")
foreign avutil {
	av_frame_alloc :: proc() -> ^AVFrame ---
	av_frame_free :: proc(frame: ^^AVFrame) ---
}

// Accessors.
format_streams :: proc "contextless" (f: ^AVFormatContext) -> []^AVStream {
	n := field(u32, f, OFF_FMT_NB_STREAMS)
	return ([^]^AVStream)(field(rawptr, f, OFF_FMT_STREAMS))[:n]
}
stream_codecpar :: proc "contextless" (s: ^AVStream) -> ^AVCodecParameters {
	return field(^AVCodecParameters, s, OFF_STREAM_CODECPAR)
}
packet_stream_index :: proc "contextless" (p: ^AVPacket) -> c.int {
	return field(c.int, p, OFF_PKT_STREAM_INDEX)
}
frame_width :: proc "contextless" (f: ^AVFrame) -> c.int {return field(c.int, f, OFF_FRAME_WIDTH)}
frame_height :: proc "contextless" (f: ^AVFrame) -> c.int {return field(
		c.int,
		f,
		OFF_FRAME_HEIGHT,
	)}
frame_format :: proc "contextless" (f: ^AVFrame) -> c.int {return field(
		c.int,
		f,
		OFF_FRAME_FORMAT,
	)}
frame_plane :: proc "contextless" (f: ^AVFrame, i: int) -> [^]u8 {
	return ([^][^]u8)(uintptr(f) + OFF_FRAME_DATA)[i]
}
frame_linesize :: proc "contextless" (f: ^AVFrame, i: int) -> c.int {
	return ([^]c.int)(uintptr(f) + OFF_FRAME_LINESIZE)[i]
}

// Decoded first video frame. Planes point into `frame`; valid until close.
First_Frame :: struct {
	frame:         ^AVFrame,
	width, height: c.int,
	pix_fmt:       c.int, // AV_PIX_FMT_*; YUV420P/YUVJ420P can go straight to libwebp
	y, u, v:       [^]u8,
	y_stride:      c.int,
	uv_stride:     c.int,
}

first_frame_close :: proc(ff: ^First_Frame) {
	if ff.frame != nil {av_frame_free(&ff.frame)}
	ff^ = {}
}

// Decodes the first video frame of `path`. Does not seek: the first packet of
// a stream is a keyframe, so this is the cheapest frame to decode.
first_frame :: proc(path: string) -> (ff: First_Frame, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	fmt_ctx: ^AVFormatContext
	if avformat_open_input(&fmt_ctx, cpath, nil, nil) < 0 {return}
	defer avformat_close_input(&fmt_ctx)
	if avformat_find_stream_info(fmt_ctx, nil) < 0 {return}

	codec: ^AVCodec
	idx := av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
	if idx < 0 || codec == nil {return}

	par := stream_codecpar(format_streams(fmt_ctx)[idx])
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
		if packet_stream_index(pkt) != idx {
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
		width     = frame_width(frame),
		height    = frame_height(frame),
		pix_fmt   = frame_format(frame),
		y         = frame_plane(frame, 0),
		u         = frame_plane(frame, 1),
		v         = frame_plane(frame, 2),
		y_stride  = frame_linesize(frame, 0),
		uv_stride = frame_linesize(frame, 1),
	}
	return ff, true
}
