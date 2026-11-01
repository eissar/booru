package replay

import "../store"
import "core:mem"
import "core:slice"

@(private)
tag_less :: proc(a, b: store.Tag_Row) -> bool {
	return a.item_id < b.item_id || (a.item_id == b.item_id && a.tag < b.tag)
}

// Sorts and compacts in place; the returned prefix borrows rows and its strings.
reduce_tags :: proc(rows: []store.Tag_Row) -> []store.Tag_Row {
	slice.sort_by(rows, tag_less)
	out := 0
	for start := 0; start < len(rows); {
		end := start + 1
		for end < len(rows) && rows[end] == rows[start] {end += 1}
		if (end - start) % 2 == 1 {
			rows[out] = rows[start]
			out += 1
		}
		start = end
	}
	return rows[:out]
}

// Inputs must be sorted, unique reduced rows. Allocates the result's storage;
// tag strings are borrowed from the inputs. Neither input is modified.
merge_tags :: proc(a, b: []store.Tag_Row, alloc: mem.Allocator) -> []store.Tag_Row {
	rows := make([]store.Tag_Row, len(a) + len(b), alloc)
	i, j, n := 0, 0, 0
	for i < len(a) && j < len(b) {
		if a[i] == b[j] {
			i += 1
			j += 1
		} else if tag_less(a[i], b[j]) {
			rows[n] = a[i]
			n += 1
			i += 1
		} else {
			rows[n] = b[j]
			n += 1
			j += 1
		}
	}
	for row in a[i:] {rows[n] = row; n += 1}
	for row in b[j:] {rows[n] = row; n += 1}
	return rows[:n]
}
