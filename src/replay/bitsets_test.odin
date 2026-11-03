package replay

import "../library"
import "../store"
import "../vendor/sqlite"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
membership_grows_across_tags_and_shards_deterministically :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	first, last: strings.Builder
	strings.builder_init(&first, alloc)
	strings.builder_init(&last, alloc)
	strings.write_string(&first, "{\"op\":\"add\",\"id\":1}\n")
	// Membership grows beyond 64 tags; every tag gets a distinct position.
	for i in 0 ..< 130 {
		fmt.sbprintf(
			&first,
			"%s%c%c%s",
			"{\"op\":\"patch\",\"id\":1,\"tags_xor\":[\"tag-",
			rune('a' + i / 26),
			rune('a' + i % 26),
			"\"]}\n",
		)
	}
	// A new item starts at a high dictionary position, leaving lower entries zero.
	strings.write_string(&first, "{\"op\":\"add\",\"id\":2,\"tags_xor\":[\"tag-ez\"]}\n")
	for i in 1 ..< 129 {
		if i == 63 || i == 64 {continue}
		fmt.sbprintf(
			&last,
			"%s%c%c%s",
			"{\"op\":\"patch\",\"id\":1,\"tags_xor\":[\"tag-",
			rune('a' + i / 26),
			rune('a' + i % 26),
			"\"]}\n",
		)
	}
	// Repeated delivery cancels, without affecting the other item's same tag.
	for _ in 0 ..< 2 {
		strings.write_string(&last, "{\"op\":\"patch\",\"id\":1,\"tags_xor\":[\"tag-ez\"]}\n")
	}
	strings.write_string(&last, "{\"op\":\"patch\",\"id\":2,\"tags_xor\":[\"tag-aa\"]}\n")
	a, b := strings.to_string(first), strings.to_string(last)
	input := strings.concatenate({a, b}, alloc)
	// Same ordered stream, single-element or multi-shard slice: identical tag identity.
	for run in 0 ..< 4 {
		s: library.State
		if !testing.expect(t, store.Init(&s, ":memory:") == sqlite.OK) {return}
		streams := []string{input} if run % 2 == 0 else []string{a, b}
		if !testing.expect(t, sqlite.run(s.data_store, "BEGIN")) {return}
		result := replay(&s, streams, context.allocator)
		testing.expect(t, result == nil)
		testing.expect(t, sqlite.run(s.data_store, result == nil ? "COMMIT" : "ROLLBACK"))
		images, rc := store.read_images(s.data_store, alloc)
		if testing.expect(t, rc == sqlite.OK && len(images) == 2) {
			testing.expect_value(t, images[0].id, 1)
			testing.expect_value(t, images[1].id, 2)
			testing.expect(
				t,
				slice.equal(images[0].tags, []string{"tag-aa", "tag-cl", "tag-cm", "tag-ez"}),
			)
			testing.expect(t, slice.equal(images[1].tags, []string{"tag-aa", "tag-ez"}))
		}
		store.Close(&s)
	}
}
