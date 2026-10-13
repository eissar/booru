package media

import "core:bytes"

Format :: enum {
	Unknown,
	PNG,
	JPEG,
	GIF,
	WebP,
	AVI,
	FLV,
	OGV,
	MPG,
	MPV,
	WMV,
	AVIF,
	MOV,
	ThreeGP,
	M4V,
	MP4,
	WebM,
	MKV,
}

has_magic :: proc(data: []u8, offset: int, magic: []u8) -> bool {
	if len(data) < offset + len(magic) {return false}
	for value, i in magic {
		if data[offset + i] != value {return false}
	}
	return true
}

detect_format :: proc(data: []u8) -> Format {
	switch {
	case has_magic(data, 0, {0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}):
		return .PNG
	case has_magic(data, 0, {0xff, 0xd8, 0xff}):
		return .JPEG
	case has_magic(data, 0, transmute([]u8)string("GIF87a")),
	     has_magic(data, 0, transmute([]u8)string("GIF89a")):
		return .GIF
	case has_magic(data, 0, transmute([]u8)string("RIFF")):
		if has_magic(data, 8, transmute([]u8)string("WEBP")) {return .WebP}
		if has_magic(data, 8, transmute([]u8)string("AVI ")) {return .AVI}
	case has_magic(data, 0, transmute([]u8)string("FLV")):
		return .FLV
	case has_magic(data, 0, transmute([]u8)string("OggS")):
		return .OGV
	case has_magic(data, 0, {0x00, 0x00, 0x01, 0xba}):
		return .MPG
	case has_magic(data, 0, {0x00, 0x00, 0x01, 0xb3}):
		return .MPV
	case has_magic(
		     data,
		     0,
		     {
			     0x30,
			     0x26,
			     0xb2,
			     0x75,
			     0x8e,
			     0x66,
			     0xcf,
			     0x11,
			     0xa6,
			     0xd9,
			     0x00,
			     0xaa,
			     0x00,
			     0x62,
			     0xce,
			     0x6c,
		     },
	     ):
		return .WMV
	case has_magic(data, 4, transmute([]u8)string("ftyp")):
		brands := data[8:min(len(data), 64)]
		if bytes.contains(brands, transmute([]u8)string("avif")) {return .AVIF}
		if bytes.contains(brands, transmute([]u8)string("qt  ")) {return .MOV}
		if bytes.contains(brands, transmute([]u8)string("3gp")) {return .ThreeGP}
		if bytes.contains(brands, transmute([]u8)string("M4V")) {return .M4V}
		return .MP4
	case has_magic(data, 0, {0x1a, 0x45, 0xdf, 0xa3}):
		header := data[:min(len(data), 4096)]
		if bytes.contains(header, transmute([]u8)string("webm")) {return .WebM}
		return .MKV
	}
	return .Unknown
}

extension :: proc(format: Format) -> string {
	switch format {
	case .Unknown:
		return ""
	case .PNG:
		return "png"
	case .JPEG:
		return "jpg"
	case .GIF:
		return "gif"
	case .WebP:
		return "webp"
	case .AVI:
		return "avi"
	case .FLV:
		return "flv"
	case .OGV:
		return "ogv"
	case .MPG:
		return "mpg"
	case .MPV:
		return "mpv"
	case .WMV:
		return "wmv"
	case .AVIF:
		return "avif"
	case .MOV:
		return "mov"
	case .ThreeGP:
		return "3gp"
	case .M4V:
		return "m4v"
	case .MP4:
		return "mp4"
	case .WebM:
		return "webm"
	case .MKV:
		return "mkv"
	}
	return ""
}
