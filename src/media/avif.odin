package media

import "core:encoding/endian"

AVIF_ALPHA_AUX_TYPE :: "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha"

AVIF_Box_Type :: enum {
	Unknown,
	EOF,
	meta,
	pitm,
	iloc,
	iprp,
	ipco,
	auxC,
	ipma,
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
	case {'i', 'p', 'r', 'p'}:
		cc = .iprp
	case {'i', 'p', 'c', 'o'}:
		cc = .ipco
	case {'a', 'u', 'x', 'C'}:
		cc = .auxC
	case {'i', 'p', 'm', 'a'}:
		cc = .ipma
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

AVIF_Box_Iterator :: struct {
	data:   []u8,
	offset: int,
}

next_box :: proc(iter: ^AVIF_Box_Iterator) -> (kind: AVIF_Box_Type, payload: []u8, ok: bool) {
	if iter.offset == len(iter.data) {return .EOF, nil, true}
	cc, size, header := parse_avif_box_header(iter.data[iter.offset:]) or_return
	payload = iter.data[iter.offset + header:iter.offset + size]
	iter.offset += size
	return cc, payload, true
}

// unreviewed
//
// Returns the primary item's file-relative byte range. Assumes a directly
// coded AV1 image; accepts one file-relative extent with no external reference.
// The decoder returns .Unsupported for non-8-bit/I420 images.
decode :: proc(data: []u8) -> (offset, length, alpha_offset, alpha_length: int, ok: bool) {
	pitm, iloc: []u8
	alpha_property_index: int
	alpha_id: u32
	boxes := AVIF_Box_Iterator {
		data = data,
	}
	for {
		cc, meta := next_box(&boxes) or_return
		if cc == .EOF {break}
		if cc != .meta {continue}
		if len(meta) < 4 || meta[0] != 0 {return}

		// meta is a FullBox; its children follow version/flags.
		children := AVIF_Box_Iterator {
			data = meta[4:],
		}
		for {
			f, box := next_box(&children) or_return
			if f == .EOF {break}
			#partial switch f {
			case .pitm:
				pitm = box
			case .iloc:
				iloc = box
			case .iprp:
				property_boxes := AVIF_Box_Iterator {
					data = box,
				}
				for {
					kind, properties := next_box(&property_boxes) or_return
					if kind == .EOF {break}
					if kind == .ipma {
						if len(properties) < 8 || properties[0] > 1 {return}
						wide := properties[3] & 1 != 0
						count, _ := endian.get_u32(properties[4:8], .Big)
						at := 8
						for _ in 0 ..< count {
							item: u32
							if properties[0] == 0 {
								if len(properties) - at < 2 {return}
								n, _ := endian.get_u16(properties[at:at + 2], .Big)
								item = u32(n)
								at += 2
							} else {
								if len(properties) - at < 4 {return}
								item, _ = endian.get_u32(properties[at:at + 4], .Big)
								at += 4
							}
							if at >= len(properties) {return}
							associations := int(properties[at])
							at += 1
							for _ in 0 ..< associations {
								index: int
								if wide {
									if len(properties) - at < 2 {return}
									n, _ := endian.get_u16(properties[at:at + 2], .Big)
									index = int(n & 0x7fff)
									at += 2
								} else {
									if at >= len(properties) {return}
									index = int(properties[at] & 0x7f)
									at += 1
								}
								if alpha_property_index != 0 && index == alpha_property_index {
									alpha_id = item
								}
							}
						}
						continue
					}
					if kind != .ipco {continue}

					properties_iter := AVIF_Box_Iterator {
						data = properties,
					}
					property_index := 0
					for {
						kind, property := next_box(&properties_iter) or_return
						if kind == .EOF {break}
						property_index += 1
						if kind != .auxC {continue}
						// auxC is a FullBox followed by a NUL-terminated auxiliary type.
						if len(property) < 5 || property[0] != 0 {return}
						end := 4
						for end < len(property) && property[end] != 0 {end += 1}
						if end == len(property) {return}
						if string(property[4:end]) == AVIF_ALPHA_AUX_TYPE {
							alpha_property_index = property_index
						}
					}
				}
			}
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
		if item != id && (alpha_id == 0 || item != alpha_id) {
			at += extent_bytes
			continue
		}

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
		if item == id {
			offset, length = int(start), int(extent_length)
		} else {
			alpha_offset, alpha_length = int(start), int(extent_length)
		}
		at += length_size
		if length != 0 && (alpha_id == 0 || alpha_length != 0) {
			return offset, length, alpha_offset, alpha_length, true
		}
	}
	return
}
