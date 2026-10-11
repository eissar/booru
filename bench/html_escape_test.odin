package bench

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import "../src/template"

@(test)
html_escape_text :: proc(t: ^testing.T) {
	cases := [?]struct {
		name, input, expected: string,
	} {
		{"plain", "Summer holiday photo 2026", "Summer holiday photo 2026"},
		{"mixed", "Tom & Jerry's <holiday>", "Tom &amp; Jerry's &lt;holiday&gt;"},
	}
	iterations :: 100_000
	warmup :: 1_000
	b: strings.Builder
	strings.builder_init(&b, 0, 256)
	defer strings.builder_destroy(&b)

	for c in cases {
		strings.builder_reset(&b)
		template.escape_text(&b, c.input)
		testing.expect_value(t, strings.to_string(b), c.expected)

		for _ in 0 ..< warmup {
			strings.builder_reset(&b)
			template.escape_text(&b, c.input)
		}

		// Consume every output byte to preserve each iteration's work. Reported
		// times include buffer reset and volatile stores, not just escaping.
		sink: u8
		start := time.tick_now()
		for _ in 0 ..< iterations {
			strings.builder_reset(&b)
			template.escape_text(&b, c.input)
			for byte in transmute([]u8)strings.to_string(b) {
				intrinsics.volatile_store(&sink, byte)
			}
		}
		elapsed := time.tick_since(start)
		testing.expect_value(t, strings.to_string(b), c.expected)
		fmt.printf(
			"escape_text/%s: %.2f ns/op (%d iterations; includes output consumption)\n",
			c.name,
			time.duration_seconds(elapsed) * 1e9 / f64(iterations),
			iterations,
		)
	}
}
