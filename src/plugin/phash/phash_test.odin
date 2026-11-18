package phash

import "core:fmt"
import "core:os"
import "core:testing"

import plugin ".."
import "../../library"
import "../../store"
import "../../vendor/sqlite"

// TODO: vendor reference test vectors from darwinium-com/pdqhash.

@(test)
test_register_job_and_find_matches :: proc(t: ^testing.T) {
	lib_dir := fmt.tprintf(
		"%s/booru_phash_test_%d",
		os.temp_dir(context.temp_allocator),
		os.get_pid(),
	)
	defer os.remove_all(lib_dir)
	testing.expect_value(t, library.init_new_library(lib_dir), nil)

	// Copy a real 128px WebP thumbnail into thumbnails/128/item1.webp.
	thumb_bytes, read_err := os.read_entire_file(
		"static/not_found_128.webp",
		context.temp_allocator,
	)
	testing.expect_value(t, read_err, nil)
	thumb_path := fmt.tprintf("%s/thumbnails/128/item1.webp", lib_dir)
	testing.expect_value(t, os.write_entire_file(thumb_path, thumb_bytes), nil)

	s: library.State
	s.library_path = lib_dir
	testing.expect_value(t, store.Init(&s, ":memory:"), sqlite.OK)
	defer store.Close(&s)

	testing.expect(t, plugin.register(&s, {PLUGIN}))
	// Idempotent second call
	testing.expect(t, plugin.register(&s, {PLUGIN}))

	// Insert two items: item 1 has a thumbnail, item 2 (e.g. PDF) does not.
	testing.expect_value(
		t,
		sqlite.exec(
			s.data_store,
			`INSERT INTO items (id, oid, path, ext, name, comment, content_type, width, height, mtime, added_at)
			 VALUES
			   (1, 'item1', 'a.png', 'png', 'a', '', 'image/png', 128, 128, 1, 1),
			   (2, 'item2', 'b.pdf', 'pdf', 'b', '', 'application/pdf', 0, 0, 1, 1);`,
			nil,
			nil,
			nil,
		),
		sqlite.OK,
	)

	testing.expect(t, plugin.run(&s, {PLUGIN}, context.allocator))

	expected, _, ok := compute_webp(thumb_path)
	testing.expect(t, ok)

	matches, match_ok := find_matches(s.data_store, expected)
	defer delete(matches)
	testing.expect(t, match_ok)
	testing.expect_value(t, len(matches), 1)
	testing.expect_value(t, matches[0].id, 1)
	testing.expect_value(t, matches[0].dist, 0)
}
