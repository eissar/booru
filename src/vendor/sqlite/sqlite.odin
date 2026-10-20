package sqlite

// Minimal SQLite3 bindings written from the public C API (sqlite3.h).
// SQLite itself is public domain. Only the subset booru needs is bound.
//
// Linking: system library by default. For a static build of the amalgamation,
// replace the import with: foreign import sqlite "libsqlite3.a"

import "core:c"

when ODIN_OS == .Windows {
	foreign import sqlite "windows-amd64/sqlite3.lib"
} else {
	foreign import sqlite "system:sqlite3"
}

DB :: struct {} // opaque sqlite3
Stmt :: struct {} // opaque sqlite3_stmt

// Result codes (subset).
OK :: 0
ROW :: 100
DONE :: 101
MISUSE :: 21

// Fundamental datatypes returned by column_type (SQLITE_INTEGER..SQLITE_NULL).
Column_Type :: enum c.int {
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
	Null    = 5,
}

// sqlite3_open_v2 flags.
OPEN_READONLY :: 0x00000001
OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004
OPEN_FULLMUTEX :: 0x00010000
OPEN_NOMUTEX :: 0x00008000

CANTOPEN :: 14 // SQLITE_CANTOPEN

// Destructor sentinel: SQLITE_TRANSIENT == (void(*)(void*))-1 makes SQLite copy the bytes.
TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite {
	// errstr returns static English text for a result code; not owned, no connection needed.
	errstr :: proc(rc: c.int) -> cstring ---
	open_v2 :: proc(filename: cstring, db: ^^DB, flags: c.int, vfs: cstring) -> c.int ---
	// close returns BUSY (and leaks the connection) while statements are unfinalized; callers must finalize first. The return code is not checked by this binding.
	close :: proc(db: ^DB) -> c.int ---
	// errmsg is per-connection: a later call on db overwrites it, so read it immediately after the failing call. The returned cstring is borrowed.
	errmsg :: proc(db: ^DB) -> cstring ---
	exec :: proc(db: ^DB, sql: cstring, cb: rawptr, arg: rawptr, err: ^cstring) -> c.int ---
	free :: proc(p: rawptr) ---

	prepare_v2 :: proc(db: ^DB, sql: cstring, n: c.int, stmt: ^^Stmt, tail: ^cstring) -> c.int ---
	step :: proc(stmt: ^Stmt) -> c.int ---
	reset :: proc(stmt: ^Stmt) -> c.int ---
	// finalize returns the error code of the statement's most recent step, not of finalize itself; callers that ignore it lose that error.
	finalize :: proc(stmt: ^Stmt) -> c.int ---
	clear_bindings :: proc(stmt: ^Stmt) -> c.int ---

	bind_int64 :: proc(stmt: ^Stmt, i: c.int, v: i64) -> c.int ---
	bind_text :: proc(stmt: ^Stmt, i: c.int, s: cstring, n: c.int, destructor: rawptr) -> c.int ---
	bind_null :: proc(stmt: ^Stmt, i: c.int) -> c.int ---

	column_int64 :: proc(stmt: ^Stmt, i: c.int) -> i64 ---
	column_text :: proc(stmt: ^Stmt, i: c.int) -> cstring ---
	column_bytes :: proc(stmt: ^Stmt, i: c.int) -> c.int ---
	column_double :: proc(stmt: ^Stmt, i: c.int) -> f64 ---
	column_blob :: proc(stmt: ^Stmt, i: c.int) -> rawptr ---
	column_type :: proc(stmt: ^Stmt, i: c.int) -> Column_Type ---
	column_count :: proc(stmt: ^Stmt) -> c.int ---

	// get_autocommit is nonzero when no transaction is open (BEGIN or SAVEPOINT).
	// Transactions are driven with run(db, "BEGIN"/"COMMIT"/"ROLLBACK") for now.
	get_autocommit :: proc(db: ^DB) -> c.int ---

	last_insert_rowid :: proc(db: ^DB) -> i64 ---
	// changes64 counts rows changed by the most recent INSERT/UPDATE/DELETE on db.
	// Requires SQLite >= 3.37.0.
	changes64 :: proc(db: ^DB) -> i64 ---
}

// open opens (creating if needed) a database for read/write.
// rc is the SQLite result code: 0 (OK) on success; otherwise db is nil and
// errstr(rc) describes the failure.
open :: proc(path: cstring) -> (db: ^DB, rc: c.int) {
	rc = open_v2(path, &db, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX, nil)
	if rc != OK {
		if db != nil {close(db)}
		return nil, rc
	}
	return db, OK
}

// prepare compiles exactly one statement. Caller must finalize it.
// Fails (stmt == nil) if sql contains no statement, or anything other than
// whitespace and ';' after the first statement (including comments). The
// remainder is only inspected, never prepared, so a rejected second statement
// cannot take effect (some PRAGMAs run at prepare time).
prepare :: proc(db: ^DB, sql: cstring) -> (stmt: ^Stmt, ok: bool) {
	tail: cstring
	if prepare_v2(db, sql, -1, &stmt, &tail) != OK || stmt == nil {
		if stmt != nil {finalize(stmt)}
		return nil, false
	}
	if tail != nil {
		bytes := cast([^]u8)tail
		for i := 0; bytes[i] != 0; i += 1 {
			switch bytes[i] {
			case ' ', '\t', '\n', '\r', '\f', ';':
			case:
				finalize(stmt)
				return nil, false
			}
		}
	}
	return stmt, true
}

// bind_string binds UTF-8 text at 1-based index i; SQLite copies the bytes.
bind_string :: proc(stmt: ^Stmt, i: int, s: string) -> bool {
	if i < 1 || i > 0x7fff_ffff || len(s) > 0x7fff_ffff {return false}
	// SQLite interprets a nil pointer as NULL, regardless of the byte count.
	p := cstring(raw_data(s))
	if len(s) == 0 {p = cstring("")}
	return bind_text(stmt, c.int(i), p, c.int(len(s)), TRANSIENT) == OK
}

// column_string returns a borrowed view valid until the next step/reset/finalize.
// Clone it (strings.clone) if you need to keep it.
// An index outside [0, column_count) returns "" (as for NULL), never another column.
column_string :: proc(stmt: ^Stmt, i: int) -> string {
	if i < 0 || i >= int(column_count(stmt)) {return ""}
	p := column_text(stmt, c.int(i))
	if p == nil {return ""}
	return string((cast([^]u8)p)[:column_bytes(stmt, c.int(i))])
}

// Tx marks a connection borrowed for the duration of with_transaction's body.
// It does not enforce ownership: do not retain it or close its connection.
Tx :: struct {
	db: ^DB,
}

// with_transaction owns BEGIN/COMMIT/ROLLBACK; body returns a SQLite result code.
// Nested transactions are rejected with MISUSE; no savepoint nesting is provided.
// The caller must exclusively own db for the entire call (FULLMUTEX does not
// prevent other users of the connection from interleaving transaction work).
// Body must finalize its statements before returning and must not close db or
// issue transaction/savepoint control, including through preprepared statements.
//
// After a successful body, autocommit being enabled returns MISUSE: the body
// ended the transaction. This cannot undo a body's COMMIT or detect COMMIT;
// BEGIN (or equivalent ROLLBACK; BEGIN). A body error is preserved, since SQLite
// can automatically roll back on errors without any callback misuse.
//
// No authorizer is installed. sqlite3_set_authorizer could deny TRANSACTION and
// SAVEPOINT actions while preparing body statements, but only one authorizer
// exists per connection and preprepared statements can bypass that protection.
//
// On body or COMMIT failure, rollback is attempted if a transaction remains.
// Rollback errors do not replace the original error; if rollback fails, db may
// still have an active transaction. This helper cannot recover from process
// termination or a body that does not return normally.
with_transaction :: proc(db: ^DB, payload: $T, body: proc(tx: ^Tx, payload: T) -> c.int) -> c.int {
	if get_autocommit(db) == 0 {
		return MISUSE
	}

	rc := exec(db, "BEGIN", nil, nil, nil)
	if rc != OK {return rc}

	defer {
		if get_autocommit(db) == 0 {
			exec(db, "ROLLBACK", nil, nil, nil)
		}
	}

	tx := Tx {
		db = db,
	}
	rc = body(&tx, payload)
	if rc != OK {return rc}

	if get_autocommit(db) != 0 {
		return MISUSE
	}

	return exec(db, "COMMIT", nil, nil, nil)
}

// run executes SQL that returns no rows (pragmas, DDL, BEGIN/COMMIT).
run :: proc(db: ^DB, sql: cstring) -> bool {
	return exec(db, sql, nil, nil, nil) == OK
}
