package thumbnail


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
