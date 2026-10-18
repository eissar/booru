package sqlite

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"

fixture :: proc(t: ^testing.T, sql: cstring) -> (^DB, ^Stmt) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK)
	s, ready := prepare(db, sql); testing.expect(t, ready)
	return db, s
}
check_scan :: proc(t: ^testing.T, sql: cstring, out: ^$T, want: Scan_Error) {
	db, s := fixture(t, sql); defer close(db); defer finalize(s)
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, scan_row(s, out), want)
}

@(test)
scanner_lossless_integer_range_enum :: proc(t: ^testing.T) {
	E :: enum i16 {
		A = -2,
		B = 300,
	}
	R :: struct {
		first: i64,
		value: i8,
	}
	Case :: struct {
		sql:  cstring,
		want: Scan_Error,
	}
	for c in ([]Case{{"select 99,128", .Integer_Range}, {"select 99,-129", .Integer_Range}, {"select 99,'bad'", .Type_Mismatch}, {"select 99,NULL", .Null_Value}}) {
		r := R{42, 7}; before := r
		db, s := fixture(t, c.sql); testing.expect_value(t, step(s), ROW)
		testing.expect_value(t, scan_row(s, &r), c.want); testing.expect_value(t, r, before)
		finalize(s); close(db)
	}
	a: struct {
		x: i64,
		y: u64,
		z: i8,
		w: u8,
	}
	check_scan(t, "select -9223372036854775808,9223372036854775807,-128,255", &a, .None)
	testing.expect_value(
		t,
		a.x,
		i64(-9223372036854775807 - 1),
	); testing.expect_value(t, a.y, u64(9223372036854775807)); testing.expect_value(t, a.z, i8(-128)); testing.expect_value(t, a.w, u8(255))
	u: struct {
		x: u64,
	}; check_scan(t, "select -1", &u, .Integer_Range)
	e: struct {
		x: E,
		y: E,
	}; check_scan(
		t,
		"select -2,'B'",
		&e,
		.None,
	); testing.expect_value(t, e.x, E.A); testing.expect_value(t, e.y, E.B)
	for sql in ([]cstring{"select 0,300", "select -2,'missing'"}) {before := e; check_scan(t, sql, &e, .Bad_Enum); testing.expect_value(t, e, before)}
}

// NULL is never scanned as zero or empty: it fails the whole row, in any
// position, leaving out^ untouched and freeing clones of earlier fields.
@(test)
scanner_null_distinct_from_zero_and_empty :: proc(t: ^testing.T) {
	R :: struct {
		n: i64,
		s: string,
		b: []u8,
		c: cstring,
	}
	for sql in ([]cstring{"select NULL,'',x'',''", "select 0,NULL,x'',''", "select 0,'',NULL,''", "select 0,'',x'',NULL"}) {
		r := R {
			n = 42,
			s = "unchanged",
		}
		check_scan(t, sql, &r, .Null_Value)
		testing.expect(t, r.n == 42 && r.s == "unchanged" && r.b == nil && r.c == nil)
	}
	r: R
	check_scan(t, "select 0,'',x'',''", &r, .None)
	testing.expect(t, r.n == 0 && r.s == "" && len(r.b) == 0 && r.c != nil && string(r.c) == "")
	delete(r.s); delete(r.b); delete(r.c)
}

@(test)
scanner_reflection_layout_supported_types :: proc(t: ^testing.T) {
	R :: struct {
		a: b8,
		b: i64,
		c: b16,
		d: f64,
		e: [3]u8,
		f: i32,
	}
	r: R; check_scan(t, "select 1,123456,0,1.5,x'010203',7", &r, .None)
	testing.expect(
		t,
		bool(r.a) && r.b == 123456 && !bool(r.c) && r.d == 1.5 && r.e == [3]u8{1, 2, 3},
	)
	testing.expect_value(t, r.f, i32(7))
	// Support is decided by type alone: these are rejected even for NULL data.
	m: struct {
		x: Maybe(i64),
	}; check_scan(t, "select 1", &m, .Unsupported); check_scan(t, "select NULL", &m, .Unsupported)
	mc: struct {
		x: Maybe(cstring),
		y: i64,
	} = {
		y = 9,
	}; check_scan(t, "select 'a',NULL", &mc, .Unsupported); testing.expect_value(t, mc.y, i64(9))
	w: struct {
		x: string16,
	}; check_scan(t, "select 'a'", &w, .Unsupported)
	nested: struct {
		x: struct {
			y: i64,
		},
	}; check_scan(t, "select 1", &nested, .Unsupported)
	// Shape errors are reported before stepping, so no row is consumed.
	{
		db, s := fixture(t, "select 1"); defer close(db); defer finalize(s)
		ok, err, rc := step_scan(s, &m)
		testing.expect(t, !ok && err == .Unsupported && rc == OK)
		testing.expect_value(t, step(s), ROW)
	}
	a: struct {
		x: []bool,
	}; check_scan(t, "select x'01'", &a, .Unsupported)
	b: struct {
		x: [1]bool,
	}; check_scan(t, "select x'01'", &b, .Unsupported)
	c: struct {
		x: i32be,
	}; check_scan(t, "select 1", &c, .Unsupported)
	d: struct {
		x: f32be,
	}; check_scan(t, "select 1.5", &d, .Unsupported)
	e: struct {
		x: ^int,
	}; check_scan(t, "select 1", &e, .Unsupported)
	short: struct {
		x: [2]u8,
	}; check_scan(t, "select x'01'", &short, .Blob_Size)
	check_scan(t, "select 1,2", &short, .Column_Count)
}

Fail_State :: struct {
	backing: mem.Allocator,
	calls:   int,
	live:    int,
	fail_at: int,
}
failing_allocator :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	loc: runtime.Source_Code_Location,
) -> (
	[]u8,
	mem.Allocator_Error,
) {
	s := cast(^Fail_State)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		s.calls += 1; if s.calls == s.fail_at {return nil, .Out_Of_Memory}
	}
	result, err := s.backing.procedure(s.backing.data, mode, size, alignment, old, old_size, loc)
	if err == nil {
		if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && len(result) > 0 {s.live += 1}
		if mode == .Free && old != nil {s.live -= 1}
	}
	return result, err
}

@(test)
scanner_owned_clones_atomic_failure :: proc(t: ^testing.T) {
	R :: struct {
		a: string,
		b: []u8,
		c: cstring,
	}
	db, s := fixture(t, "select 'hello',x'010002','world' union all select 'other',x'ff','next'")
	testing.expect_value(t, step(s), ROW)
	r: R; testing.expect_value(t, scan_row(s, &r), Scan_Error.None)
	testing.expect_value(t, step(s), ROW); reset(s); finalize(s); close(db)
	testing.expect_value(
		t,
		r.a,
		"hello",
	); testing.expect(t, len(r.b) == 3 && r.b[0] == 1 && r.b[1] == 0 && r.b[2] == 2); testing.expect_value(t, string(r.c), "world")
	delete(r.a); delete(r.b); delete(r.c)
	for fail in 1 ..= 3 {
		state := Fail_State {
			backing = context.allocator,
			fail_at = fail,
		}
		alloc := mem.Allocator {
			procedure = failing_allocator,
			data      = &state,
		}
		db, s := fixture(t, "select 'hello',x'010002','world'"); step(s)
		sentinel := R {
			a = "unchanged",
		}; before := sentinel
		testing.expect_value(t, scan_row(s, &sentinel, alloc), Scan_Error.Alloc)
		testing.expect(t, sentinel.a == before.a && sentinel.b == nil && sentinel.c == nil)
		testing.expect_value(t, state.live, 0)
		finalize(s); close(db)
	}
}

@(test)
scanner_step_result_channels :: proc(t: ^testing.T) {
	for sql, i in ([]cstring{"select 7", "select 'bad'", "select 1 where 0", "select abs(-9223372036854775808)"}) {
		db, s := fixture(t, sql); defer close(db); defer finalize(s)
		r: struct {
			x: i64,
		} = {
			x = 55,
		}; ok, err, rc := step_scan(s, &r)
		switch i {
		case 0:
			testing.expect(t, ok && err == .None && rc == ROW && r.x == 7)
			ok, err, rc = step_scan(s, &r)
			testing.expect(t, !ok && err == .None && rc == DONE)
			testing.expect_value(t, r.x, 7) // DONE leaves the previous row
		case 1:
			testing.expect(t, !ok && err == .Type_Mismatch && rc == ROW)
			testing.expect_value(t, r.x, 55)
		case 2:
			testing.expect(t, !ok && err == .None && rc == DONE)
			testing.expect_value(t, r.x, 55)
		case 3:
			testing.expect(t, !ok && err == .Step && rc != ROW && rc != DONE)
			testing.expect_value(t, r.x, 55)
		}
	}
}

@(test)
binding_empty_null_embedded_nul :: proc(t: ^testing.T) {
	db, s := fixture(t, "select ?1,?2,?3"); defer close(db); defer finalize(s)
	testing.expect(
		t,
		bind_string(s, 1, "") && bind_string(s, 2, "a\x00b"),
	); testing.expect_value(t, bind_null(s, 3), OK)
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(
		t,
		column_type(s, 0),
		Column_Type.Text,
	); testing.expect_value(t, column_bytes(s, 0), 0)
	testing.expect_value(
		t,
		column_string(s, 1),
		"a\x00b",
	); testing.expect_value(t, column_type(s, 2), Column_Type.Null)
}

@(test)
binding_transient_copies_input :: proc(t: ^testing.T) {
	db, s := fixture(t, "select ?1"); defer close(db); defer finalize(s)
	input := strings.clone("original"); testing.expect(t, bind_string(s, 1, input))
	bytes := transmute([]u8)input; bytes[0] = 'X'; delete(input)
	testing.expect_value(t, step(s), ROW); testing.expect_value(t, column_string(s, 0), "original")
}

@(test)
binding_index_range_validation :: proc(t: ^testing.T) {
	db, s := fixture(t, "select ?1"); defer close(db); defer finalize(s)
	for i in ([]int{0, -1, 2, 0x1_0000_0001, 0x8000_0000}) {testing.expect(t, !bind_string(s, i, "bad"))}
	testing.expect(
		t,
		bind_string(s, 1, "valid"),
	); testing.expect_value(t, step(s), ROW); testing.expect_value(t, column_string(s, 0), "valid")
}

@(test)
binding_reset_rebind_clear :: proc(t: ^testing.T) {
	db, s := fixture(t, "select ?1"); defer close(db); defer finalize(s)
	testing.expect(t, bind_string(s, 1, "first"))
	for _ in 0 ..< 2 {testing.expect_value(t, step(s), ROW); testing.expect_value(t, column_string(s, 0), "first"); testing.expect_value(t, reset(s), OK)}
	testing.expect(
		t,
		bind_string(s, 1, "replacement"),
	); testing.expect_value(t, step(s), ROW); testing.expect_value(t, column_string(s, 0), "replacement")
	reset(
		s,
	); testing.expect_value(t, clear_bindings(s), OK); testing.expect_value(t, step(s), ROW); testing.expect_value(t, column_type(s, 0), Column_Type.Null)
}

// prepare returns ok only with a non-nil statement for exactly one statement;
// only trailing whitespace and semicolons are allowed after the statement;
// a rejected second statement must not take effect.
@(test)
prepare_exactly_one_statement :: proc(t: ^testing.T) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK); defer close(db)
	accepted := []cstring{"select 1", "select 1;", "select 1; ;\n ", "select 'a;b'"}
	for sql in accepted {
		s, ok := prepare(db, sql)
		testing.expectf(t, ok && s != nil, "should accept %q", sql)
		if s != nil {finalize(s)}
	}
	rejected := []cstring {
		"",
		"   \n",
		"-- only a comment",
		"/* only a comment */",
		"select 1; select 2",
		"select 1; garbage",
		"select 1; -- trailing comment",
		"create table t(x); insert into t values (1)",
		"selec 1",
	}
	for sql in rejected {
		s, ok := prepare(db, sql)
		testing.expectf(t, !ok && s == nil, "should reject %q", sql)
		if s != nil {finalize(s)}
	}
	// 'a;b' is one statement: check the right query was prepared.
	s, ok := prepare(db, "select 'a;b'")
	testing.expect(t, ok)
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, column_string(s, 0), "a;b")
	finalize(s)
	// Rejecting "select 1; pragma foreign_keys=off" must not run the pragma.
	testing.expect(t, run(db, "pragma foreign_keys=on"))
	_, ok = prepare(db, "select 1; pragma foreign_keys=off")
	testing.expect(t, !ok)
	s, ok = prepare(db, "pragma foreign_keys")
	testing.expect(t, ok)
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, column_int64(s, 0), 1)
	finalize(s)
}

// Conversions must be exact or fail: no inf, no non-0/1 bool, no inexact int->float.
@(test)
scanner_lossy_conversions_rejected :: proc(t: ^testing.T) {
	f32r: struct {
		x: f32,
	}
	check_scan(t, "select 1e300", &f32r, .Float_Range)
	check_scan(t, "select 1.5", &f32r, .None)
	check_scan(t, "select 16777217", &f32r, .Integer_Range)
	check_scan(t, "select 16777216", &f32r, .None)
	testing.expect_value(t, f32r.x, 16777216)
	check_scan(t, "select 33554432", &f32r, .None) // 2^25: exact
	testing.expect_value(t, f32r.x, 33554432)
	check_scan(t, "select 33554436", &f32r, .None) // 24 significant bits
	testing.expect_value(t, f32r.x, 33554436)
	check_scan(t, "select 33554434", &f32r, .Integer_Range) // needs 25 significant bits
	f64r: struct {
		x: f64,
	}
	check_scan(t, "select 9007199254740993", &f64r, .Integer_Range)
	check_scan(t, "select 9007199254740992", &f64r, .None)
	check_scan(t, "select 18014398509481984", &f64r, .None) // 2^54: exact
	testing.expect_value(t, f64r.x, 18014398509481984)
	check_scan(t, "select 18014398509481985", &f64r, .Integer_Range)
	f16r: struct {
		x: f16,
	}
	check_scan(t, "select 1e6", &f16r, .Float_Range)
	check_scan(t, "select 2049", &f16r, .Integer_Range)
	check_scan(t, "select 2048", &f16r, .None)
	testing.expect_value(t, f16r.x, 2048)
	check_scan(t, "select 1048576", &f16r, .Float_Range) // 2^20: exact but overflows f16
	br: struct {
		x: bool,
	}
	check_scan(t, "select 2", &br, .Integer_Range)
	check_scan(t, "select -1", &br, .Integer_Range)
	check_scan(t, "select 1", &br, .None)
	testing.expect(t, br.x)
	check_scan(t, "select 0", &br, .None)
	testing.expect(t, !br.x)
}

// Transactions driven through run(): ROLLBACK discards, COMMIT persists, and
// get_autocommit tracks whether a transaction is open.
@(test)
transaction_rollback_and_commit :: proc(t: ^testing.T) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK); defer close(db)
	scalar :: proc(t: ^testing.T, db: ^DB, sql: cstring) -> i64 {
		s, ok := prepare(db, sql); testing.expect(t, ok)
		defer finalize(s)
		testing.expect_value(t, step(s), ROW)
		return column_int64(s, 0)
	}
	testing.expect(t, run(db, "create table t(x)"))
	testing.expect(t, get_autocommit(db) != 0)
	testing.expect(t, run(db, "begin") && run(db, "insert into t values (1)"))
	testing.expect(t, get_autocommit(db) == 0)
	testing.expect_value(t, scalar(t, db, "select count(*) from t"), 1)
	testing.expect(t, run(db, "rollback"))
	testing.expect(t, get_autocommit(db) != 0)
	testing.expect_value(t, scalar(t, db, "select count(*) from t"), 0)
	testing.expect(t, run(db, "begin") && run(db, "insert into t values (2)") && run(db, "commit"))
	testing.expect(t, get_autocommit(db) != 0)
	testing.expect_value(t, scalar(t, db, "select x from t"), 2)
	testing.expect(t, !run(db, "commit")) // no open transaction
}

// Negative SQL integers must not match unsigned enum members, even when the
// member's i64 bit pattern is negative (u64 above i64 max).
@(test)
scanner_unsigned_enum_rejects_negative :: proc(t: ^testing.T) {
	Big :: enum u64 {
		High = 0xffff_ffff_ffff_ffff,
		Low  = 1,
	}
	r := struct {
		x: Big,
	}{.Low}
	check_scan(t, "select -1", &r, .Bad_Enum)
	testing.expect_value(t, r.x, Big.Low)
	check_scan(t, "select 1", &r, .None)
	testing.expect_value(t, r.x, Big.Low)
	check_scan(t, "select 'High'", &r, .None) // large members stay selectable by name
	testing.expect_value(t, r.x, Big.High)
	Small :: enum i8 {
		Neg = -1,
	}
	s: struct {
		x: Small,
	}
	check_scan(t, "select -1", &s, .None) // signed enums still accept negatives
	testing.expect_value(t, s.x, Small.Neg)
}

// changes64 counts rows touched by the latest write; last_insert_rowid is 64-bit.
@(test)
changes_and_rowid_are_64_bit :: proc(t: ^testing.T) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK); defer close(db)
	testing.expect(t, run(db, "create table t(id integer primary key, x)"))
	testing.expect(t, run(db, "insert into t(x) values (1),(1),(1)"))
	testing.expect_value(t, changes64(db), 3)
	testing.expect_value(t, last_insert_rowid(db), 3)
	testing.expect(t, run(db, "update t set x = 2 where id <= 2"))
	testing.expect_value(t, changes64(db), 2)
	testing.expect(t, run(db, "update t set x = 9 where id > 100"))
	testing.expect_value(t, changes64(db), 0)
	testing.expect(t, run(db, "delete from t"))
	testing.expect_value(t, changes64(db), 3)
	testing.expect(t, run(db, "insert into t(id, x) values (5000000000, 1)"))
	testing.expect_value(t, last_insert_rowid(db), 5000000000)
}

// A cstring cannot represent embedded NUL; string can.
@(test)
scanner_cstring_rejects_embedded_nul :: proc(t: ^testing.T) {
	c := struct {
		x: cstring,
	}{"keep"}
	check_scan(t, "select cast(x'610062' as text)", &c, .Embedded_Nul)
	testing.expect_value(t, c.x, cstring("keep"))
	s: struct {
		x: string,
	}
	check_scan(t, "select cast(x'610062' as text)", &s, .None)
	testing.expect_value(t, s.x, "a\x00b")
	delete(s.x)
	check_scan(t, "select 'ab'", &c, .None)
	testing.expect_value(t, c.x, cstring("ab"))
	delete(c.x)
}

// An out-of-range column index must not wrap onto a real column.
@(test)
column_string_index_range :: proc(t: ^testing.T) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK); defer close(db)
	s, ok := prepare(db, "select 'zero', 'one'"); testing.expect(t, ok); defer finalize(s)
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, column_string(s, 1), "one")
	for i in ([]int{-1, 2, 0x1_0000_0000, 0x1_0000_0001, -0x1_0000_0000}) {
		testing.expect_value(t, column_string(s, i), "")
	}
}

// open reports why it failed; db is nil on failure.
@(test)
open_failure_reports_code :: proc(t: ^testing.T) {
	db, rc := open("/nonexistent-dir-for-test/x.db")
	testing.expect(t, db == nil)
	testing.expect_value(t, rc, CANTOPEN)
	testing.expect(t, errstr(rc) != nil)
}

// bind_int64 round-trips the full i64 range; bind_null and bind_int64 reject
// bad indices and leave the existing binding alone.
@(test)
bind_integer_and_null_index_range :: proc(t: ^testing.T) {
	db, s := fixture(t, "select ?1"); defer close(db); defer finalize(s)
	for v in ([]i64{min(i64), max(i64), 0, -1}) {
		testing.expect_value(t, bind_int64(s, 1, v), OK)
		testing.expect_value(t, step(s), ROW)
		testing.expect_value(t, column_int64(s, 0), v)
		testing.expect_value(t, reset(s), OK)
	}
	testing.expect_value(t, bind_int64(s, 1, 5), OK)
	for i in ([]i32{-1, 0, 2}) {
		testing.expect(t, bind_int64(s, i, 9) != OK)
		testing.expect(t, bind_null(s, i) != OK)
	}
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, column_int64(s, 0), 5)
	testing.expect_value(t, reset(s), OK)
	testing.expect_value(t, bind_null(s, 1), OK) // NULL replaces an integer
	testing.expect_value(t, step(s), ROW)
	testing.expect_value(t, column_type(s, 0), Column_Type.Null)
}

// A failed run returns false and errmsg describes that failure; the
// connection stays usable.
@(test)
run_failure_reports_errmsg :: proc(t: ^testing.T) {
	db, rc := open(":memory:"); testing.expect_value(t, rc, OK); defer close(db)
	testing.expect(t, !run(db, "not sql"))
	testing.expect(t, strings.contains(string(errmsg(db)), "syntax error"))
	testing.expect(t, !run(db, "insert into missing values (1)"))
	testing.expect(t, strings.contains(string(errmsg(db)), "no such table: missing"))
	testing.expect(t, run(db, "create table t(x)"))
}

check_bounds :: proc(
	t: ^testing.T,
	$I: typeid,
	lo_sql, hi_sql, below_sql, above_sql: cstring,
	lo, hi: I,
) {
	r: struct {
		x: I,
	}
	check_scan(t, lo_sql, &r, .None); testing.expect_value(t, r.x, lo)
	check_scan(t, hi_sql, &r, .None); testing.expect_value(t, r.x, hi)
	check_scan(t, below_sql, &r, .Integer_Range); testing.expect_value(t, r.x, hi)
	check_scan(t, above_sql, &r, .Integer_Range); testing.expect_value(t, r.x, hi)
}

// Every integer width accepts exactly its range; out-of-range fails and leaves
// the output untouched. (u64 is covered by scanner_lossless_integer_range_enum.)
@(test)
scanner_integer_width_bounds :: proc(t: ^testing.T) {
	check_bounds(t, i8, "select -128", "select 127", "select -129", "select 128", -128, 127)
	check_bounds(t, u8, "select 0", "select 255", "select -1", "select 256", 0, 255)
	check_bounds(
		t,
		i16,
		"select -32768",
		"select 32767",
		"select -32769",
		"select 32768",
		-32768,
		32767,
	)
	check_bounds(t, u16, "select 0", "select 65535", "select -1", "select 65536", 0, 65535)
	check_bounds(
		t,
		i32,
		"select -2147483648",
		"select 2147483647",
		"select -2147483649",
		"select 2147483648",
		-2147483648,
		2147483647,
	)
	check_bounds(
		t,
		u32,
		"select 0",
		"select 4294967295",
		"select -1",
		"select 4294967296",
		0,
		4294967295,
	)
}
