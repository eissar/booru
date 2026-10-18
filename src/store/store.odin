package store

import "../library"
import "../vendor/sqlite"
import "core:c"

// Init assigns data_store only on success. Close an existing connection first.
Init :: proc(state: ^library.State, path: cstring) -> (rc: c.int) {
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

	rc = sqlite.exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
	if rc != sqlite.OK {return rc}

	rc = sqlite.exec(
		db,
		`
		BEGIN;
		CREATE TABLE IF NOT EXISTS items (
			id INTEGER PRIMARY KEY,
			oid TEXT NOT NULL,
			path TEXT NOT NULL,
			ext TEXT NOT NULL,
			name TEXT NOT NULL,
			content_type TEXT NOT NULL,
			width INTEGER NOT NULL,
			height INTEGER NOT NULL,
			mtime TEXT NOT NULL,
			added_at TEXT NOT NULL
		);
		CREATE INDEX IF NOT EXISTS items_added_at ON items(added_at, id);
		CREATE TABLE IF NOT EXISTS item_tags (
			item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
			tag TEXT NOT NULL,
			PRIMARY KEY (item_id, tag)
		) WITHOUT ROWID;
		CREATE INDEX IF NOT EXISTS item_tags_by_tag ON item_tags(tag, item_id);
		COMMIT;
	`,
		nil,
		nil,
		nil,
	)
	if rc != sqlite.OK {return rc}

	state.data_store = db
	success = true
	return sqlite.OK
}

Close :: proc(state: ^library.State) {
	if state.data_store != nil {
		if sqlite.close(state.data_store) == sqlite.OK {
			state.data_store = nil
		}
	}
}

// events are currently unversioned.
// during event replay we check:
/*
max_event_version:= 0
max_event_version = max(max_event_version, ev.version)
*/
// so no version is 0
// we panic on replay if max_event version gt:
MAX_SUPPORTED_EVENT_VERSION :: 0

// probe_compatibility_check :: proc() {}

// Inserts item metadata; tags are stored separately in item_tags.
insert_into_items :: proc {
	insert_item,
	insert_item_tx,
}

// Owns its transaction.
@(private = "file")
insert_item :: proc(db: ^sqlite.DB, item: library.Image) -> c.int {
	return sqlite.with_transaction(db, item, insert_item_tx)
}

// Uses the caller's transaction; never commits or rolls back.
@(private = "file")
insert_item_tx :: proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
	stmt: ^sqlite.Stmt
	rc := sqlite.prepare_v2(
		tx.db,
		`INSERT INTO items (
			id, oid, path, ext, name, content_type,
			width, height, mtime, added_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		-1,
		&stmt,
		nil,
	)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return rc}

	integer_values := [3]i64{i64(item.id), i64(item.width), i64(item.height)}
	integer_indices := [3]c.int{1, 7, 8}
	for value, i in integer_values {
		rc = sqlite.bind_int64(stmt, integer_indices[i], value)
		if rc != sqlite.OK {return rc}
	}

	text_values := [7]string {
		item.oid,
		item.path,
		item.ext,
		item.name,
		item.content_type,
		item.mtime,
		item.added_at,
	}
	text_indices := [7]c.int{2, 3, 4, 5, 6, 9, 10}
	for value, i in text_values {
		if len(value) > 0x7fff_ffff {return 18} 	// SQLITE_TOOBIG
		p := cstring(raw_data(value))
		if len(value) == 0 {p = cstring("")}
		rc = sqlite.bind_text(stmt, text_indices[i], p, c.int(len(value)), sqlite.TRANSIENT)
		if rc != sqlite.OK {return rc}
	}

	rc = sqlite.step(stmt)
	if rc != sqlite.DONE {return rc}

	tag_stmt: ^sqlite.Stmt
	rc = sqlite.prepare_v2(
		tx.db,
		"INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?)",
		-1,
		&tag_stmt,
		nil,
	)
	defer {
		if tag_stmt != nil {sqlite.finalize(tag_stmt)}
	}
	if rc != sqlite.OK {return rc}

	for tag in item.tags {
		rc = sqlite.bind_int64(tag_stmt, 1, i64(item.id))
		if rc != sqlite.OK {return rc}
		if !sqlite.bind_string(tag_stmt, 2, tag) {return 1} 	// SQLITE_ERROR
		rc = sqlite.step(tag_stmt)
		if rc != sqlite.DONE {return rc}
		rc = sqlite.reset(tag_stmt)
		if rc != sqlite.OK {return rc}
	}
	return sqlite.OK
}
