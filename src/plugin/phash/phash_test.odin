package phash

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:testing"

import plugin ".."
import "../../library"
import "../../store"
import "../../vendor/sqlite"
import pdq "slop-pdqhash"

// Reference vectors: hashes computed with darwinium-com/pdqhash
// generate_pdq_full_size (bit-for-bit compatible with Meta's reference PDQ)
// on deterministic synthetic RGBA images produced by `pdq_test_image`.
PDQ_Vector :: struct {
	w, h: int,
	seed: u32,
	hash: string,
}

PDQ_VECTORS :: [?]PDQ_Vector {
	{64, 64, 1, "3355fcbe3e4cca778b01b8f5e900d25fe4db07806ab2632a65c6360bb3cbc524"},
	{100, 75, 2, "fa792f4e6a7908368af61e184ff6f005b1ae3d0af5db73853210b208b12a53ed"},
	{256, 256, 3, "b244791d6271b7f6eebd0d4e0ca0449d1671645507b3ed15b7e53a6108dfe249"},
	{512, 384, 4, "b9dc6453a93b24b16ba6aa80f38178b85d5b06b9b253678d73138f30c58ed2b9"},
	{333, 517, 5, "fd211c80639fc81a630a3ce8f7c86ca7798de24f5a5f11c47f283e1dc56c9495"},
}

pdq_test_image :: proc(w, h: int, seed: u32) -> []u8 {
	buf := make([]u8, w * h * 4, context.temp_allocator)
	s := seed
	for y in 0 ..< h {
		for x in 0 ..< w {
			s = s * 1664525 + 1013904223
			p := (y * w + x) * 4
			buf[p + 0] = u8((u32(x * 255 / (w - 1)) + (s >> 24)) / 2)
			buf[p + 1] = u8((u32(y * 255 / (h - 1)) + ((s >> 16) & 255)) / 2)
			buf[p + 2] = u8(30 + u32((x / 8 + y / 8) & 1) * 160 + (s >> 26))
			buf[p + 3] = 255
		}
	}
	return buf
}

@(test)
test_pdq_reference_vectors :: proc(t: ^testing.T) {
	for v in PDQ_VECTORS {
		rgba := pdq_test_image(v.w, v.h, v.seed)
		hash, _, ok := pdq.generate_pdq_rgba(raw_data(rgba), v.w, v.h)
		testing.expectf(t, ok, "%dx%d seed %d: hash failed", v.w, v.h, v.seed)
		got := string(hex.encode(hash[:], context.temp_allocator))
		testing.expectf(
			t,
			got == v.hash,
			"%dx%d seed %d: got %s want %s",
			v.w,
			v.h,
			v.seed,
			got,
			v.hash,
		)
	}
}

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
