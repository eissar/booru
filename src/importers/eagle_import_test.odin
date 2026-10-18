package importers

import "core:reflect"
import "core:testing"

import elog "../event_log"

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
