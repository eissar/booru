package store

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "../library"
import "../vendor/sqlite"

// Read results (including strings and tags) belong to alloc. Use a request or
// query arena: allocations made before an error also live until arena cleanup.
// No SQLite-owned pointers escape these procedures.
// The projection does not retain event-log ordering: images are ordered by id
// and tags lexically. Callers retain responsibility for filtering and sorting.
read_images :: proc(db: ^sqlite.DB, alloc: mem.Allocator) -> (images: []library.Image, rc: c.int) {
	return read_items(
		db,
		`SELECT
			i.id, i.oid, i.path, i.ext, i.width, i.height,
			i.name, i.mtime, i.added_at, i.content_type, i.comment,
			(
				SELECT json_group_array(tag)
				FROM (
					SELECT tag
					FROM item_tags
					WHERE item_id = i.id
					ORDER BY tag
				)
			) AS tags
		FROM items AS i
		ORDER BY i.id`,
		alloc,
	)
}

// Search is a literal substring match over names and tags.
// Case folding follows SQLite lower(): ASCII only.
search_images :: proc(
	db: ^sqlite.DB,
	search: string,
	tags: []string,
	sort: string,
	offset: int,
	limit: int,
	alloc: mem.Allocator,
) -> (
	page: []library.Image,
	has_more: bool,
	rc: c.int,
) {
	quoted := make([]string, len(tags), alloc)
	for tag, i in tags {
		quoted[i] = fmt.tprintf("\"%s\"", tag)
	}
	tags_json := fmt.tprintf("[%s]", strings.join(quoted, ",", alloc))
	stmt: ^sqlite.Stmt
	rc = sqlite.prepare_v2(
		db,
		`SELECT
			i.id, i.oid, i.path, i.ext, i.width, i.height,
			i.name, i.mtime, i.added_at, i.content_type, i.comment,
			(
				SELECT json_group_array(tag)
				FROM (
					SELECT tag
					FROM item_tags
					WHERE item_id = i.id
					ORDER BY tag
				)
			) AS tags
		FROM items AS i
		WHERE (instr(lower(i.name), lower(?1)) > 0
		   OR EXISTS (
				SELECT 1
				FROM item_tags AS t
				WHERE t.item_id = i.id
				  AND instr(lower(t.tag), lower(?1)) > 0
		   ))
		  AND (SELECT COUNT(*) FROM json_each(?2) AS w
		       WHERE EXISTS (
				SELECT 1 FROM item_tags AS t WHERE t.item_id = i.id AND t.tag = w.value
		       )) = (SELECT COUNT(*) FROM json_each(?2))
		ORDER BY
			CASE ?5 WHEN 'addedAtAsc'  THEN i.added_at END ASC,
			CASE ?5 WHEN 'addedAtDesc' THEN i.added_at END DESC,
			CASE ?5 WHEN 'idAsc'       THEN i.id      END ASC,
			CASE ?5 WHEN 'idDesc'      THEN i.id      END DESC,
			i.id ASC
		LIMIT ?3 OFFSET ?4`,
		-1,
		&stmt,
		nil,
	)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return nil, false, rc}
	if !sqlite.bind_string(stmt, 1, search) {return nil, false, 1}
	if !sqlite.bind_string(stmt, 2, tags_json) {return nil, false, 1}
	rc = sqlite.bind_int64(stmt, 3, i64(limit + 1))
	if rc != sqlite.OK {return nil, false, rc}
	rc = sqlite.bind_int64(stmt, 4, i64(offset))
	if rc != sqlite.OK {return nil, false, rc}
	if !sqlite.bind_string(stmt, 5, sort) {return nil, false, 1}

	out := make([dynamic]library.Image, alloc)
	for {
		row: Image_Row
		ok, err, step_rc := sqlite.step_scan(stmt, &row, alloc)
		if step_rc == sqlite.DONE {break}
		if !ok {
			if err == .Step {return nil, false, step_rc}
			if err == .Alloc {return nil, false, 7} 	// SQLITE_NOMEM
			return nil, false, 20 // SQLITE_MISMATCH
		}
		image := library.Image {
			id           = row.id,
			oid          = row.oid,
			path         = row.path,
			ext          = row.ext,
			width        = row.width,
			height       = row.height,
			name         = row.name,
			mtime        = row.mtime,
			added_at     = row.added_at,
			content_type = row.content_type,
			comment      = row.comment,
		}
		if err := json.unmarshal(transmute([]u8)row.tags, &image.tags, allocator = alloc);
		   err != nil {
			return nil, false, 20 // SQLITE_MISMATCH
		}
		append(&out, image)
	}
	has_more = len(out) > limit
	if has_more {
		return out[:limit], true, sqlite.OK
	}
	return out[:], has_more, sqlite.OK
}

read_image_by_id :: proc(
	db: ^sqlite.DB,
	id: int,
	alloc: mem.Allocator,
) -> (
	image: library.Image,
	found: bool,
	rc: c.int,
) {
	images: []library.Image
	images, rc = read_items(
		db,
		`SELECT
			i.id, i.oid, i.path, i.ext, i.width, i.height,
			i.name, i.mtime, i.added_at, i.content_type, i.comment,
			(
				SELECT json_group_array(tag)
				FROM (
					SELECT tag
					FROM item_tags
					WHERE item_id = i.id
					ORDER BY tag
				)
			) AS tags
		FROM items AS i
		WHERE i.id = ?`,
		alloc,
		id = id,
	)
	if rc != sqlite.OK || len(images) == 0 {return {}, false, rc}
	return images[0], true, sqlite.OK
}

// Batch OID lookup for thumbnail serving. LEFT JOIN from VALUES keeps the
// bound parameter order (including duplicates) and yields NULL for missing IDs.
read_oids_by_ids :: proc(
	db: ^sqlite.DB,
	ids: []int,
	alloc: mem.Allocator,
) -> (
	out: []string,
	rc: c.int,
) {
	if len(ids) == 0 {return nil, sqlite.OK}

	sql_str := fmt.caprintf(
		"SELECT items.oid FROM (VALUES %s) LEFT JOIN items ON items.id = column1",
		strings.trim_suffix(strings.repeat("(?),", len(ids), alloc), ","),
		allocator = alloc,
	)

	stmt: ^sqlite.Stmt
	rc = sqlite.prepare_v2(db, sql_str, -1, &stmt, nil)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return nil, rc}

	for id, i in ids {
		if sqlite.bind_int64(stmt, c.int(i) + 1, i64(id)) != sqlite.OK {return nil, sqlite.MISUSE}
	}

	out = make([]string, len(ids), alloc)
	for i in 0 ..< len(ids) {
		step_rc := sqlite.step(stmt)
		if step_rc != sqlite.ROW {return nil, step_rc}
		if sqlite.column_type(stmt, 0) != .Null {
			oid, err := strings.clone(sqlite.column_string(stmt, 0), alloc)
			if err != nil {return nil, 7} 	// SQLITE_NOMEM
			out[i] = oid
		}
	}
	if step_rc := sqlite.step(stmt); step_rc != sqlite.DONE {return nil, step_rc}
	return out, sqlite.OK
}

// oid is not unique in the schema. Match the first image in id order.
read_image_by_oid :: proc(
	db: ^sqlite.DB,
	oid: string,
	alloc: mem.Allocator,
) -> (
	image: library.Image,
	found: bool,
	rc: c.int,
) {
	images: []library.Image
	images, rc = read_items(
		db,
		`SELECT
			i.id, i.oid, i.path, i.ext, i.width, i.height,
			i.name, i.mtime, i.added_at, i.content_type, i.comment,
			(
				SELECT json_group_array(tag)
				FROM (
					SELECT tag
					FROM item_tags
					WHERE item_id = i.id
					ORDER BY tag
				)
			) AS tags
		FROM items AS i
		WHERE i.oid = ? ORDER BY i.id LIMIT 1`,
		alloc,
		oid = oid,
	)
	if rc != sqlite.OK || len(images) == 0 {return {}, false, rc}
	return images[0], true, sqlite.OK
}

@(private = "file")
Image_Row :: struct {
	id:           int,
	oid:          string,
	path:         string,
	ext:          string,
	width:        int,
	height:       int,
	name:         string,
	mtime:        i64,
	added_at:     i64,
	content_type: string,
	comment:      string,
	tags:         string,
}

@(private = "file")
read_items :: proc(
	db: ^sqlite.DB,
	sql: cstring,
	alloc: mem.Allocator,
	id: Maybe(int) = nil,
	oid: Maybe(string) = nil,
	search: Maybe(string) = nil,
) -> (
	images: []library.Image,
	rc: c.int,
) {
	stmt: ^sqlite.Stmt
	rc = sqlite.prepare_v2(db, sql, -1, &stmt, nil)
	defer {
		if stmt != nil {sqlite.finalize(stmt)}
	}
	if rc != sqlite.OK {return nil, rc}
	if value, ok := id.(int); ok {
		rc = sqlite.bind_int64(stmt, 1, i64(value))
		if rc != sqlite.OK {return nil, rc}
	}
	if value, ok := oid.(string); ok {
		if !sqlite.bind_string(stmt, 1, value) {return nil, 1}
	}

	if value, ok := search.(string); ok {
		if !sqlite.bind_string(stmt, 1, value) {return nil, 1}
	}

	out := make([dynamic]library.Image, alloc)
	for {
		row: Image_Row
		ok, err, step_rc := sqlite.step_scan(stmt, &row, alloc)
		if step_rc == sqlite.DONE {break}
		if !ok {
			if err == .Step {return nil, step_rc}
			if err == .Alloc {return nil, 7} 	// SQLITE_NOMEM
			return nil, 20 // SQLITE_MISMATCH
		}
		image := library.Image {
			id           = row.id,
			oid          = row.oid,
			path         = row.path,
			ext          = row.ext,
			width        = row.width,
			height       = row.height,
			name         = row.name,
			mtime        = row.mtime,
			added_at     = row.added_at,
			content_type = row.content_type,
			comment      = row.comment,
		}
		if err := json.unmarshal(transmute([]u8)row.tags, &image.tags, allocator = alloc);
		   err != nil {
			return nil, 20 // SQLITE_MISMATCH
		}
		append(&out, image)
	}
	return out[:], sqlite.OK
}
