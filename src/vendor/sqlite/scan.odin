package sqlite

// Reflection-based row scanner: copies the current row of a stepped statement
// into a struct, matching columns to fields by position.
//
// Supported field types (anything else is rejected with .Unsupported, decided
// from the type alone, before any column is read):
//   - bool, b8, b16, b32, b64                   (INTEGER)
//   - platform-endian integers of 1/2/4/8 bytes (INTEGER, range-checked)
//   - platform-endian f16, f32, f64             (REAL or INTEGER)
//   - enums with a supported integer backing    (INTEGER value or TEXT name)
//   - UTF-8 string and cstring                  (TEXT, cloned)
//   - []u8                                      (BLOB, cloned)
//   - [N]u8                                     (BLOB of exactly N bytes)
// Distinct/named types resolve to their base type.
//
// NULL is never scanned: a NULL column returns .Null_Value. Declare columns
// NOT NULL, or COALESCE nullable ones in the query.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:math"
import "core:mem"
import "core:strings"

Scan_Error :: enum {
	None,
	Column_Count, // struct field count != statement column count
	Type_Mismatch, // column storage class does not fit the field
	Null_Value, // column is NULL
	Bad_Enum, // text/integer value is not a member of the enum
	Blob_Size, // blob length differs from a fixed-size array
	Unsupported, // struct or field type the scanner does not handle
	Alloc, // clone failed
	Integer_Range, // value cannot be represented exactly (integer range, bool not 0/1, integer too large for a float)
	Float_Range, // finite REAL overflows the destination float type
	Embedded_Nul, // TEXT contains a NUL byte and the field is a cstring (use string)
	Step, // SQLite execution failed; see step_scan's rc
}

// step_scan advances the statement and scans the new row into out^.
// The struct type and column count are checked first; if they fail, the
// statement is not stepped and rc == OK.
// Otherwise rc is the SQLite step result (ROW, DONE, or an error code):
// DONE returns false/.None; execution errors return false/.Step; a row
// conversion failure returns false with its scan error and rc == ROW.
// Strings are cloned with `allocator`; the caller owns them. out^ is left untouched on failure.
step_scan :: proc(
	stmt: ^Stmt,
	out: ^$T,
	allocator := context.allocator,
) -> (
	ok: bool,
	err: Scan_Error,
	rc: c.int,
) where intrinsics.type_is_struct(T) {
	if e := check_shape(stmt, T); e != .None {return false, e, OK}
	rc = step(stmt)
	if rc == DONE {return false, .None, rc}
	if rc != ROW {return false, .Step, rc}
	err = scan_row(stmt, out, allocator)
	return err == .None, err, rc
}

// scan_row scans the current row (after a ROW from step) into out^.
// out^ is only written on success. The caller owns any previously allocated
// contents of out^.
//
// Allocator: use the heap (or a tracking allocator), or an arena. On a failed
// row, clones made so far are freed with the allocator, which releases them for
// heap allocators; an arena keeps them until it is reset or destroyed, so the
// usual pattern is one arena per query:
//     a := virtual.arena_allocator(&arena); defer virtual.arena_destroy(&arena)
// Stack and scratch allocators (LIFO-only frees) are not supported.
scan_row :: proc(
	stmt: ^Stmt,
	out: ^$T,
	allocator := context.allocator,
) -> Scan_Error where intrinsics.type_is_struct(T) {
	if e := check_shape(stmt, T); e != .None {return e}
	info := runtime.type_info_base(type_info_of(T)).variant.(runtime.Type_Info_Struct)

	row: T
	base := cast([^]u8)&row
	for i in 0 ..< int(info.field_count) {
		if e := scan_field(stmt, i, base[info.offsets[i]:], info.types[i], allocator); e != .None {
			for j in 0 ..< i {free_scan_field(base[info.offsets[j]:], info.types[j], allocator)}
			return e
		}
	}
	out^ = row
	return .None
}

// check_shape validates the struct type and the statement's column count.
@(private)
check_shape :: proc(stmt: ^Stmt, T: typeid) -> Scan_Error {
	info, is_struct := runtime.type_info_base(type_info_of(T)).variant.(runtime.Type_Info_Struct)
	if !is_struct || info.soa_kind != .None || .raw_union in info.flags {return .Unsupported}
	for i in 0 ..< int(info.field_count) {
		if !supported_field(info.types[i]) {return .Unsupported}
	}
	if int(column_count(stmt)) != int(info.field_count) {return .Column_Count}
	return .None
}

@(private)
supported_integer :: proc(ti: ^runtime.Type_Info) -> bool {
	v, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Integer)
	if !ok || v.endianness != .Platform {return false}
	switch ti.size {
	case 1, 2, 4, 8:
		return true
	}
	return false
}

@(private)
is_u8 :: proc(ti: ^runtime.Type_Info) -> bool {
	v, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Integer)
	return ok && !v.signed && v.endianness == .Platform && ti.size == 1
}

// supported_field is the complete list of accepted field types.
@(private)
supported_field :: proc(ti: ^runtime.Type_Info) -> bool {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		switch base.size {
		case 1, 2, 4, 8:
			return true
		}
	case runtime.Type_Info_Integer:
		return supported_integer(base)
	case runtime.Type_Info_Float:
		if v.endianness != .Platform {return false}
		switch base.size {
		case 2, 4, 8:
			return true
		}
	case runtime.Type_Info_Enum:
		return supported_integer(v.base)
	case runtime.Type_Info_String:
		return v.encoding == .UTF_8
	case runtime.Type_Info_Slice:
		return is_u8(v.elem)
	case runtime.Type_Info_Array:
		return is_u8(v.elem)
	}
	return false
}

@(private)
put_int :: proc(dst: [^]u8, size: int, v: i64) {
	switch size {
	case 1:
		(cast(^i8)dst)^ = i8(v)
	case 2:
		(cast(^i16)dst)^ = i16(v)
	case 4:
		(cast(^i32)dst)^ = i32(v)
	case 8:
		(cast(^i64)dst)^ = v
	}
}

// scan_field assumes supported_field(ti) has already passed.
@(private)
scan_field :: proc(
	stmt: ^Stmt,
	col: int,
	dst: [^]u8,
	ti: ^runtime.Type_Info,
	alloc: runtime.Allocator,
) -> Scan_Error {
	c := cast(i32)col
	kind := column_type(stmt, c)
	if kind == .Null {return .Null_Value}
	base := runtime.type_info_base(ti)

	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		if kind != .Integer {return .Type_Mismatch}
		raw := column_int64(stmt, c)
		if raw != 0 && raw != 1 {return .Integer_Range}
		on := raw == 1
		switch base.size {
		case 1:
			(cast(^b8)dst)^ = b8(on)
		case 2:
			(cast(^b16)dst)^ = b16(on)
		case 4:
			(cast(^b32)dst)^ = b32(on)
		case 8:
			(cast(^b64)dst)^ = b64(on)
		}
	case runtime.Type_Info_Integer:
		if kind != .Integer {return .Type_Mismatch}
		value := column_int64(stmt, c)
		bits := uint(base.size * 8)
		if v.signed {
			if bits < 64 {
				bound := i64(1) << (bits - 1)
				if value < -bound || value >= bound {return .Integer_Range}
			}
		} else {
			if value < 0 {return .Integer_Range}
			if bits < 64 && u64(value) >= (u64(1) << bits) {return .Integer_Range}
		}
		put_int(dst, base.size, value)
	case runtime.Type_Info_Float:
		// SQLite stores whole-number REALs as integers on disk but reports them as FLOAT;
		// accept either class.
		if kind != .Float && kind != .Integer {return .Type_Mismatch}
		d := column_double(stmt, c)
		if kind == .Integer {
			// Integers must convert exactly: the significant bits (bit length
			// minus trailing zeros) must fit the mantissa. Powers of two always do.
			n := column_int64(stmt, c)
			mag := n < 0 ? u64(-(n + 1)) + 1 : u64(n) // safe for min(i64)
			precision: u64
			switch base.size {
			case 2:
				precision = 11
			case 4:
				precision = 24
			case 8:
				precision = 53
			}
			if mag != 0 {
				sig :=
					64 - intrinsics.count_leading_zeros(mag) - intrinsics.count_trailing_zeros(mag)
				if sig > precision {return .Integer_Range}
			}
		}
		switch base.size {
		case 2:
			f := f16(d)
			if math.is_inf(f) && !math.is_inf(d) {return .Float_Range}
			(cast(^f16)dst)^ = f
		case 4:
			f := f32(d)
			if math.is_inf(f) && !math.is_inf(d) {return .Float_Range}
			(cast(^f32)dst)^ = f
		case 8:
			(cast(^f64)dst)^ = d
		}
	case runtime.Type_Info_Enum:
		val: i64
		found := false
		#partial switch kind {
		case .Integer:
			val = column_int64(stmt, c)
			// Values are stored as i64 bit patterns: a u64 member above i64 max
			// looks negative, so a negative SQL integer must not match unsigned enums.
			backing, _ := runtime.type_info_base(v.base).variant.(runtime.Type_Info_Integer)
			if backing.signed || val >= 0 {
				for ev in v.values {if i64(ev) == val {found = true; break}}
			}
		case .Text:
			name := column_string(stmt, col)
			for n, k in v.names {
				if n == name {val = i64(v.values[k]); found = true; break}
			}
		case:
			return .Type_Mismatch
		}
		if !found {return .Bad_Enum}
		put_int(dst, base.size, val)
	case runtime.Type_Info_String:
		if kind != .Text {return .Type_Mismatch}
		text := column_string(stmt, col)
		if v.is_cstring {
			if strings.contains_rune(text, 0) {return .Embedded_Nul}
			cs, err := strings.clone_to_cstring(text, alloc)
			if err != nil {return .Alloc}
			(cast(^cstring)dst)^ = cs
		} else {
			s, err := strings.clone(text, alloc)
			if err != nil {return .Alloc}
			(cast(^string)dst)^ = s
		}
	case runtime.Type_Info_Slice:
		if kind != .Blob {return .Type_Mismatch}
		p := column_blob(stmt, c)
		n := int(column_bytes(stmt, c))
		buf, err := make([]u8, n, alloc)
		if err != nil {return .Alloc}
		if n > 0 {mem.copy(raw_data(buf), p, n)}
		(cast(^[]u8)dst)^ = buf
	case runtime.Type_Info_Array:
		if kind != .Blob {return .Type_Mismatch}
		p := column_blob(stmt, c)
		n := int(column_bytes(stmt, c))
		if n != v.count {return .Blob_Size}
		if n > 0 {mem.copy(dst, p, n)}
	case:
		return .Unsupported
	}
	return .None
}

@(private)
free_scan_field :: proc(dst: [^]u8, ti: ^runtime.Type_Info, allocator: mem.Allocator) {
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		if v.is_cstring {delete((cast(^cstring)dst)^, allocator)} else {delete((cast(^string)dst)^, allocator)}
	case runtime.Type_Info_Slice:
		delete((cast(^[]u8)dst)^, allocator)
	}
}
