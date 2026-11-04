package store

import "core:c"

import "../library"
import "../vendor/sqlite"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
init_preserves_existing_store :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	root, err := os.make_directory_temp("", "booru-store-*", alloc)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	path, join_err := os.join_path({root, "store.sqlite"}, alloc)
	if !testing.expect(t, join_err == nil) {return}
	name := strings.clone_to_cstring(path, alloc)
	s: library.State
	if !testing.expect(t, Init(&s, name) == sqlite.OK) {return}
	if !testing.expect(
		t,
		sqlite.with_transaction(
			s.data_store,
			library.Image{id = 1, name = "preserved"},
			proc(tx: ^sqlite.Tx, item: library.Image) -> c.int {
				return insert_item(tx, item)
			},
		) ==
		sqlite.OK,
	) {
		Close(&s)
		return
	}
	Close(&s)
	if !testing.expect(t, Init(&s, name) == sqlite.OK) {return}
	defer Close(&s)
	item, found, rc := read_image_by_id(s.data_store, 1, alloc)
	testing.expect(t, rc == sqlite.OK && found && item.name == "preserved")
}
