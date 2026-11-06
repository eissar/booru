package slop_pijul

import "core:strings"

// Hunk represents an anchored line modification block:
// anchor_prev: preceding context line 1 ("" if at top or single-line context)
// anchor_curr: preceding context line 2 ("" if at top of document)
// del_lines: lines removed at this anchor.
// add_lines: lines inserted at this anchor.
@(private)
Hunk :: struct {
	anchor_prev: string,
	anchor_curr: string,
	del_lines:   [dynamic]string,
	add_lines:   [dynamic]string,
}

// Generates a human-readable, context-anchored Pijul-style patch string
// between old_text and new_text using a 2-line context anchor for uniqueness.
// If old_text == new_text, returns "".
generate_patch :: proc(old_text, new_text: string, allocator := context.allocator) -> string {
	if old_text == new_text {return ""}

	old_lines := strings.split_lines(old_text, context.temp_allocator)
	new_lines := strings.split_lines(new_text, context.temp_allocator)

	builder: strings.Builder
	strings.builder_init(&builder, allocator)

	// Context-anchored line diffing:
	// Find common prefix lines
	prefix_len := 0
	for prefix_len < len(old_lines) &&
	    prefix_len < len(new_lines) &&
	    old_lines[prefix_len] == new_lines[prefix_len] {
		prefix_len += 1
	}

	// Find common suffix lines
	suffix_len := 0
	for suffix_len < (len(old_lines) - prefix_len) &&
	    suffix_len < (len(new_lines) - prefix_len) &&
	    old_lines[len(old_lines) - 1 - suffix_len] == new_lines[len(new_lines) - 1 - suffix_len] {
		suffix_len += 1
	}

	anchor_prev := ""
	anchor_curr := ""
	if prefix_len >= 2 {
		anchor_prev = old_lines[prefix_len - 2]
		anchor_curr = old_lines[prefix_len - 1]
	} else if prefix_len == 1 {
		anchor_curr = old_lines[0]
	}

	// Format header: @@ [prev] / [curr] @@
	strings.write_string(&builder, "@@ ")
	if anchor_prev != "" {
		strings.write_string(&builder, anchor_prev)
		strings.write_string(&builder, " / ")
	}
	strings.write_string(&builder, anchor_curr)
	strings.write_string(&builder, " @@\n")

	// Deleted lines
	del_end := len(old_lines) - suffix_len
	for i in prefix_len ..< del_end {
		strings.write_string(&builder, "- ")
		strings.write_string(&builder, old_lines[i])
		strings.write_byte(&builder, '\n')
	}

	// Added lines
	add_end := len(new_lines) - suffix_len
	for i in prefix_len ..< add_end {
		strings.write_string(&builder, "+ ")
		strings.write_string(&builder, new_lines[i])
		strings.write_byte(&builder, '\n')
	}

	return strings.to_string(builder)
}

// Parses an anchored patch string into Hunks.
@(private)
parse_patch :: proc(patch_text: string, allocator := context.allocator) -> [dynamic]Hunk {
	hunks := make([dynamic]Hunk, allocator)
	lines := strings.split_lines(patch_text, context.temp_allocator)

	curr_hunk: ^Hunk
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" {continue}

		if strings.has_prefix(trimmed, "@@") && strings.has_suffix(trimmed, "@@") {
			// Anchor header: @@ [prev / ]curr @@
			content := strings.trim_space(trimmed[2:len(trimmed) - 2])
			prev := ""
			curr := content
			if slash_idx := strings.index(content, " / "); slash_idx >= 0 {
				prev = strings.trim_space(content[:slash_idx])
				curr = strings.trim_space(content[slash_idx + 3:])
			}
			append(
				&hunks,
				Hunk {
					anchor_prev = strings.clone(prev, allocator),
					anchor_curr = strings.clone(curr, allocator),
				},
			)
			curr_hunk = &hunks[len(hunks) - 1]
			curr_hunk.del_lines.allocator = allocator
			curr_hunk.add_lines.allocator = allocator
		} else if curr_hunk != nil {
			if strings.has_prefix(line, "- ") {
				append(&curr_hunk.del_lines, strings.clone(line[2:], allocator))
			} else if strings.has_prefix(line, "+ ") {
				append(&curr_hunk.add_lines, strings.clone(line[2:], allocator))
			}
		}
	}

	return hunks
}

// Applies an anchored patch to current_text using 2-line context matching.
apply_patch :: proc(current_text, patch_text: string, allocator := context.allocator) -> string {
	if patch_text == "" {return strings.clone(current_text, allocator)}

	hunks := parse_patch(patch_text, context.temp_allocator)
	lines := strings.split_lines(current_text, context.temp_allocator)

	working := make([dynamic]string, len(lines), context.temp_allocator)
	copy(working[:], lines)

	for h in hunks {
		anchor_idx := -1
		if h.anchor_curr != "" {
			for idx := 0; idx < len(working); idx += 1 {
				if working[idx] == h.anchor_curr {
					// If anchor_prev is specified, verify it matches the preceding line
					if h.anchor_prev != "" {
						if idx > 0 && working[idx - 1] == h.anchor_prev {
							anchor_idx = idx
							break
						}
					} else {
						anchor_idx = idx
						break
					}
				}
			}
		}

		insert_pos := anchor_idx + 1

		// Remove deleted lines
		for del_line in h.del_lines {
			for idx := insert_pos; idx < len(working); idx += 1 {
				if working[idx] == del_line {
					ordered_remove(&working, idx)
					break
				}
			}
		}

		// Insert added lines
		for add_line, offset in h.add_lines {
			inject_at(&working, insert_pos + offset, add_line)
		}
	}

	return strings.join(working[:], "\n", allocator)
}
