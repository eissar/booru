package store

import "../library"
import "../vendor/sqlite"
import "core:c"

// Init assigns data_store only on success. Close an existing connection first.
// Secondary indexes are never created here; replay.initiate_replay builds them
// after applying events.
Init :: proc(state: ^library.State, path: cstring, foreign_keys := true) -> (rc: c.int) {
	db, open_rc := sqlite.open(path)
	if open_rc != sqlite.OK {
		return open_rc
	}

	success := false
	defer {
		// defer rollback unless we explicitly
		// mark transact success
		if !success {
			if sqlite.get_autocommit(db) == 0 {
				sqlite.exec(db, "ROLLBACK", nil, nil, nil)
			}
			sqlite.close(db)
		}
	}

	rc = sqlite.exec(
		db,
		foreign_keys ? "PRAGMA foreign_keys = ON" : "PRAGMA foreign_keys = OFF",
		nil,
		nil,
		nil,
	)
	if rc != sqlite.OK {return rc}

	rc = create_tables(db)
	if rc != sqlite.OK {return rc}

	state.data_store = db
	if state.event_log != nil {state.event_log.db = db}
	success = true
	return sqlite.OK
}

create_tables :: proc(db: ^sqlite.DB) -> c.int {
	return sqlite.exec(
		db,
		`
		BEGIN;
		CREATE TABLE IF NOT EXISTS items (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			oid TEXT NOT NULL,
			path TEXT NOT NULL,
			ext TEXT NOT NULL,
			name TEXT NOT NULL,
			comment TEXT NOT NULL,
			content_type TEXT NOT NULL,
			width INTEGER NOT NULL,
			height INTEGER NOT NULL,
			mtime INTEGER NOT NULL,
			added_at INTEGER NOT NULL,
			deleted INTEGER NOT NULL DEFAULT 0
		);
		CREATE TABLE IF NOT EXISTS item_tags (
			item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
			tag TEXT NOT NULL,
			PRIMARY KEY (item_id, tag)
		) WITHOUT ROWID;
		CREATE TABLE IF NOT EXISTS replay_cursors (
			shard TEXT PRIMARY KEY,
			byte_offset INTEGER NOT NULL CHECK (byte_offset >= 0)
		) WITHOUT ROWID;
		COMMIT;
	`,
		nil,
		nil,
		nil,
	)
}

create_indexes :: proc(db: ^sqlite.DB) -> c.int {
	return sqlite.exec(
		db,
		`
		BEGIN;
		CREATE INDEX IF NOT EXISTS items_added_at ON items(added_at, id);
		CREATE INDEX IF NOT EXISTS item_tags_by_tag ON item_tags(tag, item_id);
		COMMIT;
	`,
		nil,
		nil,
		nil,
	)
}

Close :: proc(state: ^library.State) {
	if state.data_store != nil {
		if sqlite.close(state.data_store) == sqlite.OK {
			if state.event_log != nil && state.event_log.db == state.data_store {
				state.event_log.db = nil
			}
			state.data_store = nil
		}
	}
}

// Error is c.int-backed so None == sqlite.OK and transaction bodies can cast it.
Error :: enum c.int {
	None        = 0,
	Database    = 1, // any other sqlite failure
	NotFound    = 100, // no live row with this id (missing or soft-deleted)
	DuplicateID = 101, // insert reused an existing id (deleted or not)
}

// Uses the caller's transaction. Soft delete: the row stays so IDs are never reused.
// Fails if the item is missing or already deleted.
delete_item :: proc(tx: ^sqlite.Tx, id: int, prepared: ^sqlite.Stmt = nil) -> Error {
	stmt := prepared
	owned_stmt := stmt == nil
	rc: c.int
	if owned_stmt {
		stmt, rc = prepare_item_delete(tx.db)
		if rc != sqlite.OK {return .Database}
	}
	defer {
		if owned_stmt && stmt != nil {sqlite.finalize(stmt)}
	}
	rc = sqlite.bind_int64(stmt, 1, i64(id))
	if rc != sqlite.OK {return .Database}
	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return .Database}
	if sqlite.changes64(tx.db) == 0 {
		if !owned_stmt {sqlite.reset(stmt)}
		return .NotFound
	}
	if !owned_stmt {
		return sqlite.reset(stmt) == sqlite.OK ? .None : .Database
	}
	return .None
}

// Uses the caller's transaction. Empty/zero fields leave existing values alone.
// patch_item applies all commutative item fields (name, comment, mtime, added_at).
// Tags are toggled separately via toggle_tags.
patch_item :: proc(tx: ^sqlite.Tx, item: library.Image, prepared: ^sqlite.Stmt = nil) -> Error {
	stmt := prepared
	owned_stmt := stmt == nil
	rc: c.int
	if owned_stmt {
		stmt, rc = prepare_item_patch(tx.db)
		if rc != sqlite.OK {return .Database}
	}
	defer {
		if owned_stmt && stmt != nil {sqlite.finalize(stmt)}
	}

	if !sqlite.bind_string(stmt, 1, item.name) {return .Database}
	if !sqlite.bind_string(stmt, 2, item.comment) {return .Database}
	rc = sqlite.bind_int64(stmt, 3, item.mtime)
	if rc != sqlite.OK {return .Database}
	rc = sqlite.bind_int64(stmt, 4, item.added_at)
	if rc != sqlite.OK {return .Database}
	rc = sqlite.bind_int64(stmt, 5, i64(item.id))
	if rc != sqlite.OK {return .Database}
	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return .Database}
	if sqlite.changes64(tx.db) == 0 {
		if !owned_stmt {sqlite.reset(stmt)}
		return .NotFound
	}
	if !owned_stmt {
		return sqlite.reset(stmt) == sqlite.OK ? .None : .Database
	}
	return .None
}

// HACK: bad boundary — allows overwriting any property directly, including
// commutative fields, bypassing delta rules.
// Pointer arguments: nil leaves the column unchanged; non-nil writes the dereferenced value.
force_write_item :: proc(
	tx: ^sqlite.Tx,
	id: int,
	oid: ^string = nil,
	path: ^string = nil,
	ext: ^string = nil,
	content_type: ^string = nil,
	width: ^int = nil,
	height: ^int = nil,
	name: ^string = nil,
	comment: ^string = nil,
	mtime: ^i64 = nil,
	added_at: ^i64 = nil,
	prepared: ^sqlite.Stmt = nil,
) -> Error {
	stmt := prepared
	if stmt == nil {
		rc: c.int
		stmt, rc = prepare_item_force_write(tx.db)
		if rc != sqlite.OK {return .Database}
	}
	defer {if prepared == nil {sqlite.finalize(stmt)} else {sqlite.reset(stmt)}}

	strings_to_bind := [4]^string{oid, path, ext, content_type}
	for ptr, i in strings_to_bind {
		if ptr == nil {
			if sqlite.bind_null(stmt, c.int(i + 1)) != sqlite.OK {return .Database}
		} else if !sqlite.bind_string(stmt, i + 1, ptr^) {
			return .Database
		}
	}

	int_to_bind := [2]^int{width, height}
	for ptr, i in int_to_bind {
		if ptr == nil {
			if sqlite.bind_null(stmt, c.int(i + 5)) != sqlite.OK {return .Database}
		} else if sqlite.bind_int64(stmt, c.int(i + 5), i64(ptr^)) != sqlite.OK {
			return .Database
		}
	}

	text_to_bind := [2]^string{name, comment}
	for ptr, i in text_to_bind {
		if ptr == nil {
			if sqlite.bind_null(stmt, c.int(i + 7)) != sqlite.OK {return .Database}
		} else if !sqlite.bind_string(stmt, i + 7, ptr^) {
			return .Database
		}
	}

	i64_to_bind := [2]^i64{mtime, added_at}
	for ptr, i in i64_to_bind {
		if ptr == nil {
			if sqlite.bind_null(stmt, c.int(i + 9)) != sqlite.OK {return .Database}
		} else if sqlite.bind_int64(stmt, c.int(i + 9), ptr^) != sqlite.OK {
			return .Database
		}
	}

	if sqlite.bind_int64(stmt, 11, i64(id)) != sqlite.OK {return .Database}
	if sqlite.step(stmt) != sqlite.DONE {return .Database}
	if sqlite.changes64(tx.db) == 0 {return .NotFound}
	return .None
}

// Uses the caller's transaction. Empty/zero fields leave existing values alone.
// overwrite_item applies all LWW fields (oid, path, ext, content_type, width, height).
overwrite_item :: proc(
	tx: ^sqlite.Tx,
	item: library.Image,
	prepared: ^sqlite.Stmt = nil,
) -> Error {
	stmt := prepared
	owned_stmt := stmt == nil
	rc: c.int
	if owned_stmt {
		stmt, rc = prepare_item_overwrite(tx.db)
		if rc != sqlite.OK {return .Database}
	}
	defer {
		if owned_stmt && stmt != nil {sqlite.finalize(stmt)}
	}

	values := [4]string{item.oid, item.path, item.ext, item.content_type}
	for value, i in values {
		if !sqlite.bind_string(stmt, i + 1, value) {return .Database}
	}
	rc = sqlite.bind_int64(stmt, 5, i64(item.width))
	if rc != sqlite.OK {return .Database}
	rc = sqlite.bind_int64(stmt, 6, i64(item.height))
	if rc != sqlite.OK {return .Database}
	rc = sqlite.bind_int64(stmt, 7, i64(item.id))
	if rc != sqlite.OK {return .Database}
	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return .Database}
	if sqlite.changes64(tx.db) == 0 {
		if !owned_stmt {sqlite.reset(stmt)}
		return .NotFound
	}
	if !owned_stmt {
		return sqlite.reset(stmt) == sqlite.OK ? .None : .Database
	}
	return .None
}

// The caller owns the returned statement and must finalize it.
prepare_item_delete :: proc(db: ^sqlite.DB) -> (stmt: ^sqlite.Stmt, rc: c.int) {
	rc = sqlite.prepare_v2(
		db,
		"UPDATE items SET deleted = 1 WHERE id = ? AND deleted = 0",
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK && stmt != nil {
		sqlite.finalize(stmt)
		stmt = nil
	}
	return
}

// The caller owns the returned statement and must finalize it.
prepare_item_patch :: proc(db: ^sqlite.DB) -> (stmt: ^sqlite.Stmt, rc: c.int) {
	rc = sqlite.prepare_v2(
		db,
		`UPDATE items SET
			name = COALESCE(NULLIF(?1, ''), name),
			comment = COALESCE(NULLIF(?2, ''), comment),
			mtime = MAX(mtime, COALESCE(NULLIF(?3, 0), mtime)),
			added_at = MAX(added_at, COALESCE(NULLIF(?4, 0), added_at))
		WHERE id = ?5 AND deleted = 0`,
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK && stmt != nil {
		sqlite.finalize(stmt)
		stmt = nil
	}
	return
}

// The caller owns the returned statement and must finalize it.
prepare_item_force_write :: proc(db: ^sqlite.DB) -> (stmt: ^sqlite.Stmt, rc: c.int) {
	rc = sqlite.prepare_v2(
		db,
		`UPDATE items SET
			oid = COALESCE(?1, oid),
			path = COALESCE(?2, path),
			ext = COALESCE(?3, ext),
			content_type = COALESCE(?4, content_type),
			width = COALESCE(?5, width),
			height = COALESCE(?6, height),
			name = COALESCE(?7, name),
			comment = COALESCE(?8, comment),
			mtime = COALESCE(?9, mtime),
			added_at = COALESCE(?10, added_at)
		WHERE id = ?11 AND deleted = 0`,
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK && stmt != nil {
		sqlite.finalize(stmt)
		stmt = nil
	}
	return
}

// The caller owns the returned statement and must finalize it.
prepare_item_overwrite :: proc(db: ^sqlite.DB) -> (stmt: ^sqlite.Stmt, rc: c.int) {
	rc = sqlite.prepare_v2(
		db,
		`UPDATE items SET
			oid = COALESCE(NULLIF(?1, ''), oid),
			path = COALESCE(NULLIF(?2, ''), path),
			ext = COALESCE(NULLIF(?3, ''), ext),
			content_type = COALESCE(NULLIF(?4, ''), content_type),
			width = COALESCE(NULLIF(?5, 0), width),
			height = COALESCE(NULLIF(?6, 0), height)
		WHERE id = ?7 AND deleted = 0`,
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK && stmt != nil {
		sqlite.finalize(stmt)
		stmt = nil
	}
	return
}

// Inserts item metadata; tags are stored separately in item_tags.
// Uses the caller's transaction; never commits or rolls back.
insert_item :: proc(
	tx: ^sqlite.Tx,
	item: library.Image,
	prepared: ^sqlite.Stmt = nil,
	deleted: i64 = 0,
) -> Error {
	stmt := prepared
	owned_stmt := stmt == nil
	rc: c.int
	if owned_stmt {
		stmt, rc = prepare_item_insert(tx.db)
		if rc != sqlite.OK {return .Database}
	}
	defer {if owned_stmt {sqlite.finalize(stmt)}}

	integer_values := [6]i64 {
		i64(item.id),
		i64(item.width),
		i64(item.height),
		item.mtime,
		item.added_at,
		deleted,
	}
	integer_indices := [6]c.int{1, 7, 8, 9, 10, 12}
	for value, i in integer_values {
		rc = sqlite.bind_int64(stmt, integer_indices[i], value)
		if rc != sqlite.OK {return .Database}
	}

	text_values := [6]string {
		item.oid,
		item.path,
		item.ext,
		item.name,
		item.content_type,
		item.comment,
	}
	text_indices := [6]c.int{2, 3, 4, 5, 6, 11}
	for value, i in text_values {
		if len(value) > 0x7fff_ffff {return .Database}
		p := cstring(raw_data(value))
		if len(value) == 0 {p = cstring("")}
		rc = sqlite.bind_text(stmt, text_indices[i], p, c.int(len(value)), sqlite.TRANSIENT)
		if rc != sqlite.OK {return .Database}
	}

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return rc == 19 ? .DuplicateID : .Database}
	return sqlite.reset(stmt) == sqlite.OK ? .None : .Database
}

// The caller owns the returned statement and must finalize it.
prepare_item_insert :: proc(db: ^sqlite.DB) -> (stmt: ^sqlite.Stmt, rc: c.int) {
	rc = sqlite.prepare_v2(
		db,
		`INSERT INTO items (
			id, oid, path, ext, name, content_type,
			width, height, mtime, added_at, comment, deleted
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK && stmt != nil {
		sqlite.finalize(stmt)
		stmt = nil
	}
	return
}
