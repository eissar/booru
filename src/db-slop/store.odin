package db

import "core:c"
import "core:fmt"
import "core:strings"

// Minimal SQLite-backed image store. Binds libsqlite3 directly via core:c,
// so the only dependency is the system library (libsqlite3.so + sqlite3.h).

foreign import sqlite3 "system:sqlite3"

Sqlite3 :: struct {}
Db :: struct {}
Stmt :: struct {}

foreign sqlite3 {
	sqlite3_open :: proc(filename: cstring, ppDb: ^^Db) -> c.int ---
	sqlite3_close :: proc(db: ^Db) -> c.int ---
	sqlite3_errmsg :: proc(db: ^Db) -> cstring ---
	sqlite3_exec :: proc(db: ^Db, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: ^Db, sql: cstring, n: c.int, stmt: ^^Stmt, tail: ^cstring) -> c.int ---
	sqlite3_step :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_last_insert_rowid :: proc(db: ^Db) -> c.longlong ---
	sqlite3_changes :: proc(db: ^Db) -> c.int ---
	sqlite3_column_int64 :: proc(stmt: ^Stmt, i: c.int) -> c.longlong ---
	sqlite3_column_text :: proc(stmt: ^Stmt, i: c.int) -> cstring ---
	sqlite3_bind_text :: proc(stmt: ^Stmt, i: c.int, text: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(stmt: ^Stmt, i: c.int, v: c.longlong) -> c.int ---
}

SQLITE_OK :: c.int(0)
SQLITE_ROW :: c.int(100)
SQLITE_DONE :: c.int(101)

// SQLITE_TRANSIENT: tells sqlite to copy the bound string immediately, so the
// caller's cstring may be freed as soon as the statement steps.
SQLITE_TRANSIENT :: rawptr(uintptr(max(uintptr)))

Image :: struct {
	id:   u32,
	oid:  string,
	name: string,
	tags: []string,
}

Store :: struct {
	db:   ^Db,
	path: string,
}

// open creates or opens the store at path and ensures the schema exists.
open :: proc(path: string) -> (s: Store, err: string) {
	s.path = strings.clone(path)

	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	if rc := sqlite3_open(cpath, &s.db); rc != SQLITE_OK {
		// s.db is still valid on most open errors, so errmsg works here.
		err = fmt.tprintf("open %s: %s", path, errmsg(&s))
		if s.db != nil {sqlite3_close(s.db)}
		delete(s.path)
		s = {}
		return
	}

	schema := `CREATE TABLE IF NOT EXISTS images (
		id INTEGER PRIMARY KEY,
		oid TEXT NOT NULL,
		name TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS tags (
		image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
		tag TEXT NOT NULL,
		PRIMARY KEY (image_id, tag)
	);
	CREATE INDEX IF NOT EXISTS tags_tag_idx ON tags(tag);`

	cschema := strings.clone_to_cstring(schema)
	defer delete(cschema)

	if rc := sqlite3_exec(s.db, cschema, nil, nil, nil); rc != SQLITE_OK {
		err = fmt.tprintf("schema: %s", errmsg(&s))
		sqlite3_close(s.db)
		delete(s.path)
		s = {}
		return
	}

	return s, ""
}

close :: proc(s: ^Store) {
	if s.db != nil {sqlite3_close(s.db)}
	delete(s.path)
	s^ = {}
}

// insert stores one image and its tags in a single transaction and returns the
// allocated id. Tags are written with the image, so a failure rolls back both.
insert :: proc(s: ^Store, oid, name: string, tags: []string) -> (id: u32, err: string) {
	if rc := exec(s, "BEGIN"); rc != "" {return 0, rc}

	img: ^Stmt
	defer sqlite3_finalize(img)
	if rc := prepare(s, "INSERT INTO images (oid, name) VALUES (?, ?)", &img); rc != "" {
		exec(s, "ROLLBACK")
		return 0, rc
	}
	bind_text(img, 1, oid)
	bind_text(img, 2, name)
	if rc := sqlite3_step(img); rc != SQLITE_DONE {
		exec(s, "ROLLBACK")
		return 0, fmt.tprintf("insert %q: %s", name, errmsg(s))
	}

	id = u32(sqlite3_last_insert_rowid(s.db))

	if len(tags) > 0 {
		tag: ^Stmt
		defer sqlite3_finalize(tag)
		if rc := prepare(s, "INSERT OR IGNORE INTO tags (image_id, tag) VALUES (?, ?)", &tag);
		   rc != "" {
			exec(s, "ROLLBACK")
			return 0, rc
		}
		for t in tags {
			sqlite3_reset(tag)
			sqlite3_bind_int64(tag, 1, c.longlong(id))
			bind_text(tag, 2, t)
			if rc := sqlite3_step(tag); rc != SQLITE_DONE {
				exec(s, "ROLLBACK")
				return 0, fmt.tprintf("insert tag %q: %s", t, errmsg(s))
			}
		}
	}

	if rc := exec(s, "COMMIT"); rc != "" {return 0, rc}
	return id, ""
}

// get returns one image with its tags. Caller owns the returned strings.
get :: proc(s: ^Store, id: u32) -> (img: Image, ok: bool, err: string) {
	stmt: ^Stmt
	defer sqlite3_finalize(stmt)
	if rc := prepare(s, "SELECT id, oid, name FROM images WHERE id = ?", &stmt); rc != "" {
		return {}, false, rc
	}
	sqlite3_bind_int64(stmt, 1, c.longlong(id))

	if rc := sqlite3_step(stmt); rc != SQLITE_ROW {
		if rc == SQLITE_DONE {return {}, false, ""}
		return {}, false, fmt.tprintf("get %d: %s", id, errmsg(s))
	}

	img.id = u32(sqlite3_column_int64(stmt, 0))
	img.oid = column_clone(stmt, 1)
	img.name = column_clone(stmt, 2)

	tags, tag_err := tags_for(s, img.id)
	if tag_err != "" {
		delete(img.oid)
		delete(img.name)
		return {}, false, tag_err
	}
	img.tags = tags

	return img, true, ""
}

// by_tag returns ids of images carrying tag, ordered by id.
by_tag :: proc(s: ^Store, tag: string) -> (ids: []u32, err: string) {
	stmt: ^Stmt
	defer sqlite3_finalize(stmt)
	if rc := prepare(s, "SELECT image_id FROM tags WHERE tag = ? ORDER BY image_id", &stmt);
	   rc != "" {
		return nil, rc
	}
	bind_text(stmt, 1, tag)

	out := make([dynamic]u32)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE {break}
		if rc != SQLITE_ROW {
			delete(out)
			return nil, fmt.tprintf("by_tag %q: %s", tag, errmsg(s))
		}
		append(&out, u32(sqlite3_column_int64(stmt, 0)))
	}
	return out[:], ""
}

count :: proc(s: ^Store) -> (n: int, err: string) {
	stmt: ^Stmt
	defer sqlite3_finalize(stmt)
	if rc := prepare(s, "SELECT COUNT(*) FROM images", &stmt); rc != "" {return 0, rc}
	if rc := sqlite3_step(stmt); rc != SQLITE_ROW {
		return 0, fmt.tprintf("count: %s", errmsg(s))
	}
	return int(sqlite3_column_int64(stmt, 0)), ""
}

// delete_image removes an image and its tags (tags cascade).
delete_image :: proc(s: ^Store, id: u32) -> (removed: bool, err: string) {
	if rc := exec(s, "PRAGMA foreign_keys = ON"); rc != "" {return false, rc}

	stmt: ^Stmt
	defer sqlite3_finalize(stmt)
	if rc := prepare(s, "DELETE FROM images WHERE id = ?", &stmt); rc != "" {return false, rc}
	sqlite3_bind_int64(stmt, 1, c.longlong(id))

	if rc := sqlite3_step(stmt); rc != SQLITE_DONE {
		return false, fmt.tprintf("delete %d: %s", id, errmsg(s))
	}
	return sqlite3_changes(s.db) > 0, ""
}

free_image :: proc(img: ^Image) {
	delete(img.oid)
	delete(img.name)
	for t in img.tags {delete(t)}
	delete(img.tags)
	img^ = {}
}

@(private)
tags_for :: proc(s: ^Store, image_id: u32) -> (tags: []string, err: string) {
	stmt: ^Stmt
	defer sqlite3_finalize(stmt)
	if rc := prepare(s, "SELECT tag FROM tags WHERE image_id = ? ORDER BY tag", &stmt); rc != "" {
		return nil, rc
	}
	sqlite3_bind_int64(stmt, 1, c.longlong(image_id))

	out := make([dynamic]string)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE {break}
		if rc != SQLITE_ROW {
			for t in out {delete(t)}
			delete(out)
			return nil, fmt.tprintf("tags for %d: %s", image_id, errmsg(s))
		}
		append(&out, column_clone(stmt, 0))
	}
	return out[:], ""
}

@(private)
prepare :: proc(s: ^Store, sql: string, stmt: ^^Stmt) -> (err: string) {
	csql := strings.clone_to_cstring(sql)
	defer delete(csql)

	if rc := sqlite3_prepare_v2(s.db, csql, -1, stmt, nil); rc != SQLITE_OK {
		return fmt.tprintf("prepare %q: %s", sql, errmsg(s))
	}
	return ""
}

@(private)
exec :: proc(s: ^Store, sql: string) -> (err: string) {
	csql := strings.clone_to_cstring(sql)
	defer delete(csql)

	if rc := sqlite3_exec(s.db, csql, nil, nil, nil); rc != SQLITE_OK {
		return fmt.tprintf("exec %q: %s", sql, errmsg(s))
	}
	return ""
}

@(private)
bind_text :: proc(stmt: ^Stmt, i: c.int, text: string) {
	ctext := strings.clone_to_cstring(text)
	defer delete(ctext)
	// SQLITE_TRANSIENT makes sqlite copy before we free ctext above.
	sqlite3_bind_text(stmt, i, ctext, -1, SQLITE_TRANSIENT)
}

@(private)
column_clone :: proc(stmt: ^Stmt, i: c.int) -> string {
	text := sqlite3_column_text(stmt, i)
	if text == nil {return ""}
	return strings.clone(string(text))
}

@(private)
errmsg :: proc(s: ^Store) -> string {
	if s.db == nil {return "no database"}
	return string(sqlite3_errmsg(s.db))
}
