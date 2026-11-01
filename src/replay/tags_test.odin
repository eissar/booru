package replay

import "../store"
import "core:slice"
import "core:testing"

@(test)
reduction_permutations_partitions_and_duplicate_delivery :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	input := [?]store.Tag_Row {
		{2, "cat"},
		{1, "dog"},
		{1, "cat"},
		{2, "cat"},
		{1, "cat"},
		{1, "cat"},
	}
	expected := []store.Tag_Row{{1, "cat"}, {1, "dog"}}
	permutations := slice.make_permutation_iterator(input[:], alloc)
	defer slice.destroy_permutation_iterator(permutations, alloc)
	count := 0
	for slice.permute(&permutations) {
		work := input
		testing.expect(t, slice.equal(reduce_tags(work[:]), expected))
		count += 1
	}
	testing.expect_value(t, count, 720)
	// Every assignment to two partitions must merge to the same reduction.
	for mask in 0 ..< (1 << len(input)) {
		a, b: [len(input)]store.Tag_Row
		na, nb := 0, 0
		for row, i in input {
			if mask & (1 << uint(i)) != 0 {a[na] = row; na += 1} else {b[nb] = row; nb += 1}
		}
		ra, rb := reduce_tags(a[:na]), reduce_tags(b[:nb])
		testing.expect(t, slice.equal(merge_tags(ra, rb, alloc), expected))
		testing.expect(t, slice.equal(merge_tags(rb, ra, alloc), expected))
	}
	// XOR delivery is not idempotent: two copies cancel, three equal one.
	delivered: [dynamic]store.Tag_Row
	delivered.allocator = alloc
	append(&delivered, ..input[:])
	append(&delivered, ..input[:])
	testing.expect_value(t, len(reduce_tags(delivered[:])), 0)
	clear(&delivered)
	for _ in 0 ..< 3 {append(&delivered, ..input[:])}
	testing.expect(t, slice.equal(reduce_tags(delivered[:]), expected))
	testing.expect_value(t, len(merge_tags(expected, expected, alloc)), 0)
	testing.expect(t, slice.equal(merge_tags(nil, expected, alloc), expected))
	testing.expect_value(t, len(reduce_tags(nil)), 0)
	// Associativity for independently reduced partitions.
	a := []store.Tag_Row{{1, "cat"}, {2, "dog"}}
	b := []store.Tag_Row{{1, "cat"}, {3, "fox"}}
	c := []store.Tag_Row{{2, "dog"}, {4, "yak"}}
	left := merge_tags(merge_tags(a, b, alloc), c, alloc)
	right := merge_tags(a, merge_tags(b, c, alloc), alloc)
	testing.expect(t, slice.equal(left, right))
}
