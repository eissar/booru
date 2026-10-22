// Decode-only bindings for the bundled FFmpeg 9.x libraries.
package ffmpeg

import "core:c"

when ODIN_OS == .Windows {
	foreign import avformat "windows-amd64/avformat.lib"
	foreign import avcodec "windows-amd64/avcodec.lib"
	foreign import avutil "windows-amd64/avutil.lib"
} else {
	foreign import avformat "system:avformat"
	foreign import avcodec "system:avcodec"
	foreign import avutil "system:avutil"
}

AVClass :: struct {}
AVInputFormat :: struct {}
AVOutputFormat :: struct {}
AVIOContext :: struct {}
AVBufferRef :: struct {}

// Public struct prefixes, in header order. FFmpeg owns allocation and lifetime.
// These are incomplete: do not allocate, copy by value, or use their size for C.
AVFormatContext :: struct {
	av_class:   ^AVClass,
	iformat:    ^AVInputFormat,
	oformat:    ^AVOutputFormat,
	priv_data:  rawptr,
	pb:         ^AVIOContext,
	ctx_flags:  c.int,
	nb_streams: c.uint,
	streams:    [^]^AVStream,
}
AVCodecContext :: struct {}
AVCodec :: struct {}
AVDictionary :: struct {}
AVStream :: struct {
	av_class: ^AVClass,
	index:    c.int,
	id:       c.int,
	codecpar: ^AVCodecParameters,
}
AVCodecParameters :: struct {}
AVPacket :: struct {
	buf:          ^AVBufferRef,
	pts:          i64,
	dts:          i64,
	data:         [^]u8,
	size:         c.int,
	stream_index: c.int,
}
AVFrame :: struct {
	data:          [8][^]u8,
	linesize:      [8]c.int,
	extended_data: [^][^]u8,
	width:         c.int,
	height:        c.int,
	nb_samples:    c.int,
	format:        c.int,
}

AVMEDIA_TYPE_VIDEO :: 0
AV_PIX_FMT_YUV420P :: 0
AV_PIX_FMT_YUVJ420P :: 12
AV_NOPTS_VALUE :: i64(-0x8000000000000000)
AV_TIME_BASE :: 1000000
AVERROR_EOF :: -541478725 // FFERRTAG('E','O','F',' ')
AVERROR_EAGAIN :: -11 // AVERROR(EAGAIN) on Linux
AVDISCARD_NONKEY :: 32

@(default_calling_convention = "c")
foreign avformat {
	avformat_open_input :: proc(ps: ^^AVFormatContext, url: cstring, fmt: ^AVInputFormat, options: ^^AVDictionary) -> c.int ---
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
