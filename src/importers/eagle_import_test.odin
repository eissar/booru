package importers

import "core:os"
import "core:reflect"
import "core:sys/linux"
import "core:testing"

import elog "../event_log"
import "../library"
import "../replay"
import "../store"
import "../vendor/sqlite"

FIXTURE_EAGLE_LIBRARY :: "test/fixture/eagle/fixture.library/images"

// EagleItem_Event is transmuted into Event, so both must have the same
// field names in the same order, at the same offsets, with the same sizes.
// Types may differ (e.g. Iso_Time vs string) as long as the layout matches.
@(test)
eagle_item_transmutable_into_event :: proc(t: ^testing.T) {
	src := reflect.struct_fields_zipped(EagleItem_Event)
	dst := reflect.struct_fields_zipped(elog.Event)

	if !testing.expectf(t, len(src) == len(dst), "field count: %d != %d", len(src), len(dst)) {
		return
	}

	for i in 0 ..< len(src) {
		s, d := src[i], dst[i]
		testing.expectf(t, s.name == d.name, "field %d name: %q != %q", i, s.name, d.name)
		testing.expectf(
			t,
			s.offset == d.offset,
			"field %q offset: %d != %d (Event.%s)",
			s.name,
			s.offset,
			d.offset,
			d.name,
		)
		testing.expectf(
			t,
			s.type.size == d.type.size,
			"field %q size: %d != %d",
			s.name,
			s.type.size,
			d.type.size,
		)
	}
}

// End to end: import writes the event log and the store; replaying that log
// into a fresh store must yield the same number of items.
@(test)
eagle_items_import_into_sqlite_with_correct_amount_of_items :: proc(t: ^testing.T) {
	fd, err := os.open(FIXTURE_EAGLE_LIBRARY, {.Read}, os.Permissions_Default)
	if !testing.expectf(t, err == nil, "open fixture %v: %v", FIXTURE_EAGLE_LIBRARY, err) {return}
	defer os.close(fd)

	root, temp_err := os.make_directory_temp("", "booru-eagle-import-*", context.allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	init_err := library.init_new_library(root)
	if !testing.expectf(t, init_err == nil, "init library: %v", init_err) {return}

	log := elog.EventLog {
		root = root,
	}
	imported := library.State {
		library_path = root,
		event_log    = &log,
	}
	if !testing.expect(t, store.Init(&imported, ":memory:") == sqlite.OK) {return}
	defer store.Close(&imported)
	res := eagle_import(FIXTURE_EAGLE_LIBRARY, &imported, linux.Fd(os.fd(fd)))
	testing.expect(
		t,
		res.success == 3 && res.missing == 1 && res.read_errors == 0,
		"import counts: 3 imported, 1 missing metadata, 0 read errors",
	)

	replayed := library.State {
		library_path = root,
	}
	if !testing.expect(t, store.Init(&replayed, ":memory:") == sqlite.OK) {return}
	defer store.Close(&replayed)
	replay.initiate_replay(&replayed)

	from_import, rc_import := store.read_images(imported.data_store, context.temp_allocator)
	from_replay, rc_replay := store.read_images(replayed.data_store, context.temp_allocator)
	testing.expect(t, rc_import == sqlite.OK && rc_replay == sqlite.OK, "read items")
	testing.expect(
		t,
		len(from_import) == 3 && len(from_replay) == 3,
		"3 eagle items in the import store and in a store replayed from its event log",
	)
}
