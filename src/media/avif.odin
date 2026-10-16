package media

import "core:encoding/endian"

AVIF_Box_Type :: enum {
	Unknown,
	meta,
	pitm,
	iloc,
}

// FullBox version semantics depend on the box type; these notes describe iloc.
Fullbox_Version :: enum u8 {
	V0 = 0, // 16-bit item IDs/count; no construction method or extent index.
	V1 = 1, // Adds construction method and optional extent index; IDs/count stay 16-bit.
	V2 = 2, // Retains V1 fields; item IDs/count become 32-bit.
}

// Box size includes the header. Unlike RIFF, boxes have no even-byte padding.
parse_avif_box_header :: proc(data: []u8) -> (cc: AVIF_Box_Type, size, header_sz: int, ok: bool) {
	if len(data) < 8 {return}
	fourcc := [4]u8{data[4], data[5], data[6], data[7]}
	switch fourcc {
	case {'m', 'e', 't', 'a'}:
		cc = .meta
	case {'p', 'i', 't', 'm'}:
		cc = .pitm
	case {'i', 'l', 'o', 'c'}:
		cc = .iloc
	}
	n, _ := endian.get_u32(data[:4], .Big)
	header_sz = 8
	box_size := u64(n)
	switch n {
	case 0:
		box_size = u64(len(data))
	case 1:
		if len(data) < 16 {return}
		box_size, _ = endian.get_u64(data[8:16], .Big)
		header_sz = 16
	}
	if fourcc == {'u', 'u', 'i', 'd'} {header_sz += 16}
	if box_size < u64(header_sz) || box_size > u64(len(data)) {return}
	return cc, int(box_size), header_sz, true
}

// unreviewed
//
// Returns the primary item's file-relative byte range. Assumes a directly
// coded AV1 image; accepts one file-relative extent with no external reference.
// TODO: Return .Unsupported for non-8-bit/I420 images rather than treating them as supported thumbnail input.
Parse_AVIF :: proc(data: []u8) -> (offset, length: int, ok: bool) {
	pitm, iloc: []u8
	for at := 0; at < len(data); {
		cc, size, header_sz, header_ok := parse_avif_box_header(data[at:])
		if !header_ok {return}
		start, end := at + header_sz, at + size
		at = end
		if cc != .meta {continue}
		if end - start < 4 || data[start] != 0 {return}

		// meta is a FullBox; its children follow version/flags.
		for child := start + 4; child < end; {
			f, l, h, child_ok := parse_avif_box_header(data[child:end])
			if !child_ok {return}
			box := data[child + h:child + l]
			#partial switch f {
			case .pitm:
				pitm = box
			case .iloc:
				iloc = box
			}
			child += l
		}
		break
	}
	if len(pitm) < 4 || len(iloc) < 6 {return}

	// Keep the primary item ID on the stack; iloc entries need not be ordered.
	id: u32
	#partial switch Fullbox_Version(pitm[0]) {
	case .V0:
		if len(pitm) < 6 {return}
		n, _ := endian.get_u16(pitm[4:6], .Big)
		id = u32(n)
	case .V1:
		if len(pitm) < 8 {return}
		id, _ = endian.get_u32(pitm[4:8], .Big)
	case:
		return
	}

	if iloc[0] > u8(Fullbox_Version.V2) {return}
	iloc_version := Fullbox_Version(iloc[0])
	offset_size := int(iloc[4] >> 4)
	length_size := int(iloc[4] & 0x0f)
	base_size := int(iloc[5] >> 4)
	index_size := 0
	if iloc_version != .V0 {index_size = int(iloc[5] & 0x0f)}
	if offset_size > 8 || length_size > 8 || base_size > 8 || index_size > 8 {return}

	at := 6
	count: u32
	if iloc_version != .V2 {
		if len(iloc) - at < 2 {return}
		n, _ := endian.get_u16(iloc[at:at + 2], .Big)
		count = u32(n)
		at += 2
	} else {
		if len(iloc) - at < 4 {return}
		count, _ = endian.get_u32(iloc[at:at + 4], .Big)
		at += 4
	}

	for _ in 0 ..< count {
		item: u32
		if iloc_version != .V2 {
			if len(iloc) - at < 2 {return}
			n, _ := endian.get_u16(iloc[at:at + 2], .Big)
			item = u32(n)
			at += 2
		} else {
			if len(iloc) - at < 4 {return}
			item, _ = endian.get_u32(iloc[at:at + 4], .Big)
			at += 4
		}
		method_at := at
		if iloc_version != .V0 {at += 2}
		reference_at := at
		base_at := reference_at + 2
		at = base_at + base_size
		if len(iloc) - at < 2 {return}
		extents, _ := endian.get_u16(iloc[at:at + 2], .Big)
		at += 2

		extent_size := index_size + offset_size + length_size
		extent_bytes := int(extents) * extent_size
		if extent_bytes > len(iloc) - at {return}
		if item != id {
			at += extent_bytes
			continue
		}

		// Only locates the primary AV1 bytes; optional features such as alpha are left for later.
		if extents != 1 {return}
		if iloc_version != .V0 {
			method, _ := endian.get_u16(iloc[method_at:method_at + 2], .Big)
			if method & 0x0f != 0 {return}
		}
		reference, _ := endian.get_u16(iloc[reference_at:reference_at + 2], .Big)
		if reference != 0 {return}

		base, extent_offset, extent_length: u64
		for b in iloc[base_at:base_at + base_size] {base = (base << 8) | u64(b)}
		at += index_size
		for b in iloc[at:at + offset_size] {extent_offset = (extent_offset << 8) | u64(b)}
		at += offset_size
		for b in iloc[at:at + length_size] {extent_length = (extent_length << 8) | u64(b)}

		if extent_offset > max(u64) - base {return}
		start := base + extent_offset
		if start > u64(len(data)) || extent_length == 0 {return}
		if extent_length > u64(len(data)) - start {return}
		return int(start), int(extent_length), true
	}
	return
}
