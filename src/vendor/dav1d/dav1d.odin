package dav1d

import "core:c"

// C ABI bindings for the vendored dav1d 1.5.4 headers.
// Link against a separately built libdav1d; vendoring source does not build it.
foreign import dav1d "system:dav1d"

Dav1dContext :: struct {}
Dav1dRef :: struct {}
Dav1dSequenceHeader :: struct {}
Dav1dFrameHeader :: struct {}
Dav1dContentLightLevel :: struct {}
Dav1dMasteringDisplay :: struct {}
Dav1dITUTT35 :: struct {}

Dav1dPixelLayout :: enum c.int {
	I400,
	I420,
	I422,
	I444,
}

Dav1dInloopFilterType :: enum c.int {
	NONE        = 0,
	DEBLOCK     = 1,
	CDEF        = 2,
	RESTORATION = 4,
	ALL         = 7,
}

Dav1dDecodeFrameType :: enum c.int {
	ALL,
	REFERENCE,
	INTRA,
	KEY,
}

Dav1dUserData :: struct {
	data: [^]u8,
	ref:  ^Dav1dRef,
}

Dav1dDataProps :: struct {
	timestamp: i64,
	duration:  i64,
	offset:    i64,
	size:      c.size_t,
	user_data: Dav1dUserData,
}

Dav1dData :: struct {
	data: [^]u8,
	sz:   c.size_t,
	ref:  ^Dav1dRef,
	m:    Dav1dDataProps,
}

Dav1dPictureParameters :: struct {
	w:      c.int,
	h:      c.int,
	layout: Dav1dPixelLayout,
	bpc:    c.int,
}

// Preserve the complete layout even though the thumbnail path only reads
// data, stride, and p. Metadata behind opaque pointers is not exposed.
Dav1dPicture :: struct {
	seq_hdr:               ^Dav1dSequenceHeader,
	frame_hdr:             ^Dav1dFrameHeader,
	data:                  [3]rawptr,
	stride:                [2]c.ptrdiff_t,
	p:                     Dav1dPictureParameters,
	m:                     Dav1dDataProps,
	content_light:         ^Dav1dContentLightLevel,
	mastering_display:     ^Dav1dMasteringDisplay,
	itut_t35:              ^Dav1dITUTT35,
	n_itut_t35:            c.size_t,
	reserved:              [4]uintptr,
	frame_hdr_ref:         ^Dav1dRef,
	seq_hdr_ref:           ^Dav1dRef,
	content_light_ref:     ^Dav1dRef,
	mastering_display_ref: ^Dav1dRef,
	itut_t35_ref:          ^Dav1dRef,
	reserved_ref:          [4]uintptr,
	ref:                   ^Dav1dRef,
	allocator_data:        rawptr,
}

Dav1dPicAllocator :: struct {
	cookie:                   rawptr,
	alloc_picture_callback:   proc "c" (pic: ^Dav1dPicture, cookie: rawptr) -> c.int,
	release_picture_callback: proc "c" (pic: ^Dav1dPicture, cookie: rawptr),
}

Dav1dLogger :: struct {
	cookie:   rawptr,
	// Opaque C function pointer: (void *, const char *, va_list) -> void.
	// Leave the default callback intact or set nil; no logging binding needed.
	callback: rawptr,
}

Dav1dSettings :: struct {
	n_threads:               c.int,
	max_frame_delay:         c.int,
	apply_grain:             c.int,
	operating_point:         c.int,
	all_layers:              c.int,
	frame_size_limit:        c.uint,
	allocator:               Dav1dPicAllocator,
	logger:                  Dav1dLogger,
	strict_std_compliance:   c.int,
	output_invisible_frames: c.int,
	inloop_filters:          Dav1dInloopFilterType,
	decode_frame_type:       Dav1dDecodeFrameType,
	reserved:                [16]u8,
}

Dav1dDataFreeCallback :: proc "c" (buf: [^]u8, cookie: rawptr)

foreign dav1d {
	// Initialize settings before open; zeroed settings are not the defaults.
	dav1d_default_settings :: proc(s: ^Dav1dSettings) ---
	dav1d_open :: proc(c_out: ^^Dav1dContext, s: ^Dav1dSettings) -> c.int ---

	// Wrap extracted AV1 bytes, not an AVIF container. No copy is made.
	// Supply a no-op C callback for borrowed bytes and retain their storage
	// until all input references have been released (including by close).
	dav1d_data_wrap :: proc(data: ^Dav1dData, buf: [^]u8, sz: c.size_t, free_callback: Dav1dDataFreeCallback, cookie: rawptr) -> c.int ---

	// Success transfers input ownership. On -EAGAIN, get a picture and retry
	// the remaining input. Other errors leave input owned by the caller.
	dav1d_send_data :: proc(ctx: ^Dav1dContext, data: ^Dav1dData) -> c.int ---

	// Zero-initialize the output. Success returns an owned picture reference;
	// -EAGAIN means more input is needed (or draining has finished).
	// For the assumed 8-bit I420 input: data[0..2] are Y/U/V byte planes;
	// stride[0] is Y byte stride, stride[1] is shared by U and V.
	dav1d_get_picture :: proc(ctx: ^Dav1dContext, out: ^Dav1dPicture) -> c.int ---

	// Release any unconsumed input on early exit/error.
	dav1d_data_unref :: proc(data: ^Dav1dData) ---
	// Plane pointers become invalid after releasing their picture reference.
	dav1d_picture_unref :: proc(p: ^Dav1dPicture) ---
	dav1d_close :: proc(c_out: ^^Dav1dContext) ---
}
