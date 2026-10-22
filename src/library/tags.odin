package library

import elog "../event_log"

// Tag constraints
//
// A valid tag is non-empty and contains only lowercase ASCII letters and
// '-'. Uppercase ASCII letters are accepted on input and lowercased
// (see event_log.is_allowed_tag_char for the allowed set).
//
// canonicalize_tag is a single byte scan:
//   - 'A'..'Z' are lowercased
//   - bytes allowed by is_allowed_tag_char are kept
//   - every other byte (whitespace, digits, punctuation, each byte of a
//     non-ASCII rune) is replaced with '-'; a run of such bytes becomes a
//     single '-', and runs at the start or end are dropped
//
// '-' already present in the input is kept as is, so "a - b" becomes "a---b".
// The result can be empty ("", "   ", "123"); callers must reject that.
// Distinct inputs can canonicalize to the same tag ("Cat" and "cat",
// "black cat" and "black-cat"), so callers should deduplicate afterwards.
canonicalize_tag :: proc(tag: string, allocator := context.allocator) -> string {
	out := make([]u8, len(tag), allocator)
	n := 0
	pending_dash := false
	for i in 0 ..< len(tag) {
		b := tag[i]
		if 'A' <= b && b <= 'Z' {b += 'a' - 'A'}
		if elog.is_allowed_tag_char(rune(b)) {
			if pending_dash && n > 0 {
				out[n] = '-'
				n += 1
			}
			pending_dash = false
			out[n] = b
			n += 1
		} else {
			pending_dash = true
		}
	}
	return string(out[:n])
}

// Lowercases 'A'..'Z' and turns each run of ASCII whitespace into a single
// '-' (runs at the start or end are dropped). Every other byte, including
// digits, punctuation and non-ASCII, is copied unchanged and left for
// remediation.
lowercase_and_dash_whitespace :: proc(tag: string, allocator := context.allocator) -> string {
	out := make([]u8, len(tag), allocator)
	n := 0
	pending_dash := false
	for i in 0 ..< len(tag) {
		b := tag[i]
		switch b {
		case ' ', '\t', '\n', '\v', '\f', '\r':
			pending_dash = true
			continue
		case 'A' ..= 'Z':
			b += 'a' - 'A'
		}
		if pending_dash && n > 0 {
			out[n] = '-'
			n += 1
		}
		pending_dash = false
		out[n] = b
		n += 1
	}
	return string(out[:n])
}
