// Closes the `// mull-on` regions written in Odin sources, so mull only
// mutates the decl that follows each marker.
//
// Usage: odin run test/tools/mutate_annotate.odin -file -- <file.odin>...
//
// In the source, put `// mull-on` on the line above a top-level decl. Run this
// on a scratch copy of the tree, never on the worktree: it appends
// `// mull-off` to the package line and to the line after each marked decl.
// Appending keeps line numbers stable, so mull's reports still point at the
// right place. Every file with at least one marker is printed to stdout;
// other files are left alone.
package mutate_annotate

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"

MARKER :: "mull-on"

decl_start :: proc(decl: ^ast.Stmt) -> int {
	if vd, ok := decl.derived.(^ast.Value_Decl); ok && len(vd.attributes) > 0 {
		return vd.attributes[0].pos.line
	}
	return decl.pos.line
}

annotate :: proc(path: string) -> (marked: bool, ok: bool) {
	src, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("mutate_annotate: cannot read", path, err)
		return
	}
	file := ast.File {
		src      = string(src),
		fullpath = path,
	}
	p := parser.default_parser()
	if !parser.parse_file(&p, &file) || p.error_count > 0 {
		fmt.eprintln("mutate_annotate: cannot parse", path)
		return
	}

	// 1-based line -> mull-off goes at the end of it
	off := make(map[int]bool)
	ok = true
	for group in file.comments {
		for c in group.list {
			text := strings.trim_space(strings.trim_prefix(c.text, "//"))
			if text != MARKER {
				continue
			}
			line := c.pos.line
			next: ^ast.Stmt
			for d in file.decls {
				if decl_start(d) <= line && line <= d.end.line {
					fmt.eprintf(
						"%s:%d: `// mull-on` inside a decl; put it above one\n",
						path,
						line,
					)
					ok = false
					break
				}
				if decl_start(d) > line {
					next = d
					break
				}
			}
			if next == nil {
				if ok {
					fmt.eprintf("%s:%d: `// mull-on` has no decl after it\n", path, line)
				}
				ok = false
				continue
			}
			off[next.end.line + 1] = true
			marked = true
		}
	}
	if !ok || !marked {
		return false, ok
	}
	off[file.pkg_decl.pos.line] = true

	lines := strings.split(string(src), "\n")
	b := strings.builder_make()
	for line, i in lines {
		strings.write_string(&b, line)
		// An adjacent marked decl keeps the region open.
		if off[i + 1] && !strings.contains(line, MARKER) {
			strings.write_string(&b, " // mull-off")
		}
		if i + 1 < len(lines) {
			strings.write_byte(&b, '\n')
		}
	}
	if os.write_entire_file(path, strings.to_string(b)) != nil {
		fmt.eprintln("mutate_annotate: cannot write", path)
		return false, false
	}
	return true, true
}

main :: proc() {
	failed := false
	for path in os.args[1:] {
		marked, ok := annotate(path)
		if !ok {
			failed = true
		} else if marked {
			fmt.println(path)
		}
	}
	if failed {
		os.exit(1)
	}
}
