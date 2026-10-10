package thumbnail

import "core:fmt"
import "core:strings"

// Print labeled bytes to stderr. Uses bounded stack storage, not heap allocations.
// Large dumps are emitted in batches; ordinary dumps use one print call.
dump_hex :: proc(label: string, data: []u8) {
	label := label
	storage: [4096]u8
	buf := strings.builder_from_bytes(storage[:])
	// Bound the label so formatting cannot grow the stack-backed builder.
	for len(label) > 1024 {
		fmt.eprint(label[:1024])
		label = label[1024:]
	}
	fmt.sbprintf(&buf, "%s (%d bytes):", label, len(data))
	for b, i in data {
		if len(strings.to_string(buf)) > 3000 {
			fmt.eprint(strings.to_string(buf))
			strings.builder_reset(&buf)
		}
		if i % 16 == 0 {
			fmt.sbprintf(&buf, "\n  %04x:", i)
		}
		fmt.sbprintf(&buf, " %02x", b)
	}
	fmt.eprintln(strings.to_string(buf))
}
