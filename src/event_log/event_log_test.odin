package event_log

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
remediation_validates_before_writing :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "booru-remediation-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	defer os.remove_all(root)
	path := fmt.tprintf("%s/remediation.ndjson", root)
	file, open_err := os.open(path, {.Write, .Create}, os.Permissions_Default)
	if !testing.expect(t, open_err == nil) {return}
	defer os.close(file)
	rem := EventRemediation{Event{id = 1, op = "add", tags = {"cat"}}, {"Cat!"}}
	if !testing.expect(t, ev_append(file, rem) == "") {return}
	before, read_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	testing.expect(t, strings.contains(string(before), `"tags":["cat"]`))
	testing.expect(t, strings.contains(string(before), `"REMEDIATE_tags":["Cat!"]`))
	rem.tags = {"cat", "cat"}
	testing.expect(t, ev_append(file, rem) != "")
	rem.tags = {"cat"}
	rem.REMEDIATE_tags = {strings.repeat("é", MAX_RECORD, context.temp_allocator)}
	testing.expect(t, ev_append(file, rem) != "")
	after, after_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, after_err == nil && string(before) == string(after))
}

@(test)
validate_event_tags :: proc(t: ^testing.T) {
	invalid := [][]string {
		{"same", "same"},
		{""},
		{"Upper"},
		{"two words"},
		{"under_score"},
		{"a1"},
		{"é"},
	}
	for tags in invalid {
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		e := Event {
			tags = tags,
		}
		testing.expect(t, encode_event(e, &ascii) != "")
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 0)
		defer bytes.buffer_destroy(&buf)
		testing.expect(t, write_event(bytes.buffer_to_stream(&buf), e) != "")
		testing.expect(t, bytes.buffer_length(&buf) == 0)
	}
	{
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		testing.expect(t, encode_event(Event{tags = {"lower-case", "other", "-"}}, &ascii) == "")
	}
	{
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		testing.expect(t, encode_event(Event{}, &ascii) == "")
	}
	{
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		testing.expect(t, encode_event(Event{id = 1, op = "delete"}, &ascii) == "")
	}
	{
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		testing.expect(t, encode_event(Event{id = 1, op = "delete", name = "x"}, &ascii) != "")
	}
	{
		ascii: strings.Builder
		strings.builder_init(&ascii)
		defer strings.builder_destroy(&ascii)
		testing.expect(t, encode_event(Event{id = 1, op = "delete", tags = {"cat"}}, &ascii) != "")
	}
}

@(test)
encoded_event_size_and_field :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, 0)
	defer bytes.buffer_destroy(&buf)
	w := bytes.buffer_to_stream(&buf)
	testing.expect(t, write_event(w, Event{tags = {"a"}, name = "é😀"}) == "")
	text := bytes.buffer_to_string(&buf)
	testing.expect(t, strings.contains(text, `"tags":["a"]`))
	testing.expect(t, !strings.contains(text, `"tags_xor":`))
	testing.expect(t, strings.contains(text, `\u00e9\ud83d\ude00`))
	for b in text {testing.expect(t, b < 128)}

	bytes.buffer_reset(&buf)
	// Raw UTF-8 fits, but ASCII Unicode escapes exceed the record limit.
	name := strings.repeat("é", 400)
	defer delete(name)
	e := Event {
		name = name,
	}
	ascii: strings.Builder
	strings.builder_init(&ascii)
	defer strings.builder_destroy(&ascii)
	testing.expect(t, encode_event(e, &ascii) != "")
	testing.expect(t, write_event(w, e) != "")
	testing.expect(t, bytes.buffer_length(&buf) == 0)

	// The newline does not count: 2047 payload bytes pass, 2048 fail.
	testing.expect(t, write_event(w, Event{name = "a"}) == "")
	overhead := bytes.buffer_length(&buf) - 2
	for size in MAX_RECORD - 1 ..= MAX_RECORD {
		bytes.buffer_reset(&buf)
		boundary := strings.repeat("a", size - overhead)
		defer delete(boundary)
		err := write_event(w, Event{name = boundary})
		testing.expect(t, (err == "") == (size < MAX_RECORD))
		if err == "" {testing.expect(t, bytes.buffer_length(&buf) == MAX_RECORD)}
	}
}

@(test)
invalid_batch_writes_nothing :: proc(t: ^testing.T) {
	root, temp_err := os.make_directory_temp("", "booru-event-log-*", context.temp_allocator)
	if !testing.expect(t, temp_err == nil) {return}
	defer os.remove_all(root)
	testing.expect(
		t,
		os.mkdir_all(fmt.tprintf("%s/events", root), os.Permissions_Default_Directory) == nil,
	)
	cursor: Cursor
	log := EventLog {
		root   = root,
		cursor = &cursor,
	}
	testing.expect(t, ev_append(&log, []Event{{id = 1}}) == "")
	path := fmt.tprintf("%s/events/%s", root, string(cursor.shard[:]))
	before, read_err := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, read_err == nil) {return}
	defer delete(before)
	offset := cursor.offset
	oversized := strings.repeat("😀", 200)
	defer delete(oversized)
	invalid_events := []Event{{tags = {"a", "a"}}, {tags = {"Upper"}}, {name = oversized}}
	for invalid in invalid_events {
		testing.expect(t, ev_append(&log, []Event{{id = 2}, invalid}) != "")
		after, err := os.read_entire_file(path, context.allocator)
		defer delete(after)
		testing.expect(t, err == nil)
		testing.expect(t, string(after) == string(before))
		testing.expect(t, cursor.offset == offset)
	}
}
