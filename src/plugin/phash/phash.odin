package phash

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"

import plugin ".."
import "../../library"
import "../../progress"
import "../../vendor/libwebp"
import "../../vendor/sqlite"
import pdq "slop-pdqhash"

Hash :: pdq.Hash

Match :: struct {
	id:   int,
	dist: int,
}

PLUGIN :: plugin.NativePlugin {
	name    = "phash",
	columns = {{name = "pdq", sql_type = "BLOB"}},
	run     = run,
}

compute_webp :: proc(
	path: string,
	alloc := context.allocator,
) -> (
	hash: Hash,
	quality: f32,
	ok: bool,
) {
	data, err := os.read_entire_file(path, alloc)
	if err != nil {return {}, 0, false}
	defer delete(data, alloc)

	w, h: c.int
	rgba := libwebp.WebPDecodeRGBA(raw_data(data), len(data), &w, &h)
	if rgba == nil {return {}, 0, false}
	defer libwebp.WebPFree(rgba)

	return pdq.generate_pdq_rgba(rgba, int(w), int(h), alloc)
}

// run hashes all unhashed live items using thumbnails/128/<oid>.webp inside the caller's transaction.
// Missing or unsupported thumbnails are skipped.
run :: proc(s: ^library.State, alloc: mem.Allocator) -> (processed: int, ok: bool) {
	if s == nil || s.data_store == nil {return 0, false}
	db := s.data_store

	progress.update("startup.phash", 0)
	defer progress.finish("startup.phash")

	sel: ^sqlite.Stmt
	if sqlite.prepare_v2(
		   db,
		   "SELECT id, oid FROM items WHERE deleted = 0 AND pdq IS NULL ORDER BY id",
		   -1,
		   &sel,
		   nil,
	   ) !=
	   sqlite.OK {
		return 0, false
	}
	defer sqlite.finalize(sel)

	upd: ^sqlite.Stmt
	if sqlite.prepare_v2(db, "UPDATE items SET pdq = ?1 WHERE id = ?2", -1, &upd, nil) !=
	   sqlite.OK {
		return 0, false
	}
	defer sqlite.finalize(upd)

	for {
		step_rc := sqlite.step(sel)
		if step_rc == sqlite.DONE {break}
		if step_rc != sqlite.ROW {return processed, false}

		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		id := int(sqlite.column_int64(sel, 0))
		oid := sqlite.column_string(sel, 1)
		thumb_path := fmt.tprintf("%s/thumbnails/128/%s.webp", s.library_path, oid)
		hash, _, hash_ok := compute_webp(thumb_path, alloc)
		if !hash_ok {continue}

		sqlite.reset(upd)
		if sqlite.bind_blob(upd, 1, &hash[0], len(hash), sqlite.TRANSIENT) != sqlite.OK {
			return processed, false
		}
		if sqlite.bind_int64(upd, 2, i64(id)) != sqlite.OK {
			return processed, false
		}
		if sqlite.step(upd) != sqlite.DONE {
			return processed, false
		}
		processed += 1
		progress.update("startup.phash", u64(processed))
	}
	return processed, true
}

find_matches :: proc(
	db: ^sqlite.DB,
	target: Hash,
	max_dist := 31,
	alloc := context.allocator,
) -> (
	matches: []Match,
	ok: bool,
) {
	stmt: ^sqlite.Stmt
	if sqlite.prepare_v2(
		   db,
		   "SELECT id, pdq FROM items WHERE deleted = 0 AND pdq IS NOT NULL",
		   -1,
		   &stmt,
		   nil,
	   ) !=
	   sqlite.OK {
		return nil, false
	}
	defer sqlite.finalize(stmt)

	out := make([dynamic]Match, alloc)
	for {
		step_rc := sqlite.step(stmt)
		if step_rc == sqlite.DONE {break}
		if step_rc != sqlite.ROW {
			delete(out)
			return nil, false
		}
		if sqlite.column_bytes(stmt, 1) != pdq.HASH_LENGTH {continue}
		ptr := cast([^]u8)sqlite.column_blob(stmt, 1)
		if ptr == nil {continue}
		candidate: Hash
		copy(candidate[:], ptr[:pdq.HASH_LENGTH])
		dist := pdq.hamming_distance(target, candidate)
		if dist <= max_dist {
			append(&out, Match{id = int(sqlite.column_int64(stmt, 0)), dist = dist})
		}
	}
	return out[:], true
}
