package store

import "core:c"
import "core:mem"

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
		"SELECT id, oid, path, ext, width, height, name, mtime, added_at, content_type FROM items ORDER BY id",
		alloc,
	)
}

// Search is a literal substring match over names and tags.
// Case folding follows SQLite lower(): ASCII only.
// Empty search preserves read_images behavior.
search_images :: proc(
	db: ^sqlite.DB,
	search: string,
	alloc: mem.Allocator,
) -> (
	images: []library.Image,
	rc: c.int,
) {
	if search == "" {return read_images(db, alloc)}
	return read_items(
		db,
		`
		SELECT
			i.id, i.oid, i.path, i.ext, i.width, i.height,
			i.name, i.mtime, i.added_at, i.content_type
		FROM items AS i
		WHERE instr(lower(i.name), lower(?1)) > 0
		   OR EXISTS (
				SELECT 1
				FROM item_tags AS t
				WHERE t.item_id = i.id
				  AND instr(lower(t.tag), lower(?1)) > 0
		   )
		ORDER BY i.id
		`,
		alloc,
		search = search,
	)
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
		"SELECT id, oid, path, ext, width, height, name, mtime, added_at, content_type FROM items WHERE id = ?",
		alloc,
		id = id,
	)
	if rc != sqlite.OK || len(images) == 0 {return {}, false, rc}
	return images[0], true, sqlite.OK
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
		"SELECT id, oid, path, ext, width, height, name, mtime, added_at, content_type FROM items WHERE oid = ? ORDER BY id LIMIT 1",
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

	tags: ^sqlite.Stmt
	rc = sqlite.prepare_v2(
		db,
		"SELECT tag FROM item_tags WHERE item_id = ? ORDER BY tag",
		-1,
		&tags,
		nil,
	)
	defer {
		if tags != nil {sqlite.finalize(tags)}
	}
	if rc != sqlite.OK {return nil, rc}

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
		}
		rc = sqlite.bind_int64(tags, 1, i64(row.id))
		if rc != sqlite.OK {return nil, rc}
		image_tags := make([dynamic]string, alloc)
		for {
			tag: struct {
				value: string,
			}
			tag_ok, tag_err, tag_rc := sqlite.step_scan(tags, &tag, alloc)
			if tag_rc == sqlite.DONE {break}
			if !tag_ok {
				if tag_err == .Step {return nil, tag_rc}
				if tag_err == .Alloc {return nil, 7}
				return nil, 20
			}
			append(&image_tags, tag.value)
		}
		image.tags = image_tags[:]
		rc = sqlite.reset(tags)
		if rc != sqlite.OK {return nil, rc}
		append(&out, image)
	}
	return out[:], sqlite.OK
}
