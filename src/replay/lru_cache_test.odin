package replay

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
swap_record_roundtrips_lengths_over_u16 :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-swap-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	swap := init_swap(root, max_id = 4, prealloc_bytes = 2 * 1024 * 1024)
	defer destroy_swap(&swap)

	// Every length is above max(u16); the last tag word is non-zero so it is kept.
	big := Patch_State {
		mtime    = 7,
		added_at = 8,
		name     = make([dynamic]u8, 70_000, alloc),
		comment  = strings.repeat("c", 70_001, alloc),
		tags     = make([dynamic]u64, 65_537, alloc),
	}
	for &b, i in big.name {b = u8(i % 251 + 1)}
	big.tags[0] = 1
	big.tags[65_536] = 1 << 63
	small := Patch_State {
		mtime    = 9,
		added_at = 10,
		name     = make([dynamic]u8, 2, alloc),
		comment  = "next",
	}
	copy(small.name[:], "ok")
	(^u64)(&small.tags)^ = 5
	swap_write(&swap, 1, &big)
	swap_write(&swap, 2, &small)

	got := swap_read(&swap, 1, alloc)
	testing.expect(t, got.mtime == 7 && got.added_at == 8)
	testing.expect(t, slice.equal(got.name[:], big.name[:]))
	testing.expect_value(t, got.comment, big.comment)
	testing.expect(t, slice.equal(got.tags[:], big.tags[:]))

	next := swap_read(&swap, 2, alloc)
	testing.expect(t, next.mtime == 9 && next.added_at == 10)
	testing.expect_value(t, string(next.name[:]), "ok")
	testing.expect_value(t, next.comment, "next")
	testing.expect_value(t, (^u64)(&next.tags)^, 5)
}
