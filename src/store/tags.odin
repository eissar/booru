package store

import "../vendor/sqlite"
import "core:c"

Tag_Row :: struct {
	item_id: int,
	tag:     string,
}

// Uses the caller's transaction. Each occurrence flips membership once.
// Call alongside the metadata change inside with_transaction.
toggle_tags :: proc(tx: ^sqlite.Tx, id: int, tags: []string) -> c.int {
	if sqlite.get_autocommit(tx.db) != 0 {return sqlite.MISUSE}
	remove, insert: ^sqlite.Stmt
	defer {
		if remove != nil {sqlite.finalize(remove)}
		if insert != nil {sqlite.finalize(insert)}
	}
	rc := sqlite.prepare_v2(
		tx.db,
		"DELETE FROM item_tags WHERE item_id = ? AND tag = ?",
		-1,
		&remove,
		nil,
	)
	if rc != sqlite.OK {return rc}
	rc = sqlite.prepare_v2(
		tx.db,
		"INSERT INTO item_tags (item_id, tag) VALUES (?, ?)",
		-1,
		&insert,
		nil,
	)
	if rc != sqlite.OK {return rc}
	for tag in tags {
		rc = sqlite.bind_int64(remove, 1, i64(id))
		if rc != sqlite.OK {return rc}
		if !sqlite.bind_string(remove, 2, tag) {return 1}
		rc = sqlite.step(remove)
		if rc != sqlite.DONE {return rc}
		removed := sqlite.changes64(tx.db)
		rc = sqlite.reset(remove)
		if rc != sqlite.OK {return rc}
		if removed != 0 {continue}
		rc = sqlite.bind_int64(insert, 1, i64(id))
		if rc != sqlite.OK {return rc}
		if !sqlite.bind_string(insert, 2, tag) {return 1}
		rc = sqlite.step(insert)
		if rc != sqlite.DONE {return rc}
		rc = sqlite.reset(insert)
		if rc != sqlite.OK {return rc}
	}
	return sqlite.OK
}

// Rows have already been reduced to unique odd-count memberships. Deleted
// items are filtered here, after the ordered lifecycle scan has completed.
insert_reduced_tags :: proc(tx: ^sqlite.Tx, rows: []Tag_Row) -> c.int {
	if sqlite.get_autocommit(tx.db) != 0 {return sqlite.MISUSE}
	stmt: ^sqlite.Stmt
	defer {if stmt != nil {sqlite.finalize(stmt)}}
	rc := sqlite.prepare_v2(
		tx.db,
		"INSERT INTO item_tags (item_id, tag) SELECT id, ?2 FROM items WHERE id = ?1",
		-1,
		&stmt,
		nil,
	)
	if rc != sqlite.OK {return rc}
	for row in rows {
		rc = sqlite.bind_int64(stmt, 1, i64(row.item_id))
		if rc != sqlite.OK {return rc}
		if !sqlite.bind_string(stmt, 2, row.tag) {return 1}
		rc = sqlite.step(stmt)
		if rc != sqlite.DONE {return rc}
		rc = sqlite.reset(stmt)
		if rc != sqlite.OK {return rc}
	}
	return sqlite.OK
}
