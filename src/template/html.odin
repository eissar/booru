package template

import "core:fmt"
import "core:strings"

// escape_attr escapes text for use inside a double-quoted HTML attribute.
escape_attr :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case:
			strings.write_rune(b, r)
		}
	}
}

// escape_text escapes text for use as HTML element content.
escape_text :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case:
			strings.write_rune(b, r)
		}
	}
}

// wr writes a raw literal.
wr :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
}

// wrf writes a formatted literal.
wrf :: proc(b: ^strings.Builder, format: string, args: ..any) {
	strings.write_string(b, fmt.tprintf(format, ..args))
}

// attr writes `name="value"` with value escaped.
attr :: proc(b: ^strings.Builder, name, value: string) {
	wrf(b, " %s=\"", name)
	escape_attr(b, value)
	wr(b, "\"")
}

// ia writes `name="<int>"`.
ia :: proc(b: ^strings.Builder, name: string, value: int) {
	wrf(b, " %s=\"%d\"", name, value)
}

// itoa formats an integer without allocating via fmt.
itoa :: proc(value: int) -> string {
	return fmt.tprintf("%d", value)
}

// aspect_style formats the CSS aspect-ratio style string.
aspect_style :: proc(width, height: int) -> string {
	return fmt.tprintf("aspect-ratio: %d/%d", width, height)
}
