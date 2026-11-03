// Rewrites Odin sources in place so mull only mutates procs marked @(mutate).
//
// Usage: odin run test/tools/mutate_annotate.odin -file -- <file.odin>...
//
// Run it on a scratch copy of the tree, never on the worktree: it appends
// mull-off / mull-on comments to existing lines (line numbers stay stable, so
// mull's reports still point at the right place). Every file that holds at
// least one @(mutate) decl is printed to stdout; other files are left alone.
package mutate_annotate

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"

has_mutate :: proc(decl: ^ast.Value_Decl) -> bool {
	for attr in decl.attributes {
		for elem in attr.elems {
			name := elem
			if fv, ok := elem.derived.(^ast.Field_Value); ok {
				name = fv.field
			}
			if ident, ok := name.derived.(^ast.Ident); ok && ident.name == "mutate" {
				return true
			}
		}
	}
	return false
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

	lines := strings.split(string(src), "\n")
	// 1-based line -> suffix to append
	suffix := make(map[int]string)
	for d in file.decls {
		decl, is_value := d.derived.(^ast.Value_Decl)
		if !is_value || !has_mutate(decl) {
			continue
		}
		marked = true
		suffix[decl.attributes[0].pos.line] = " // mull-on"
		suffix[decl.end.line + 1] = " // mull-off"
	}
	if !marked {
		return false, true
	}
	suffix[file.pkg_decl.pos.line] = " // mull-off"

	b := strings.builder_make()
	for line, i in lines {
		strings.write_string(&b, line)
		if s, has := suffix[i + 1]; has {
			strings.write_string(&b, s)
		}
		if i + 1 < len(lines) {
			strings.write_byte(&b, '\n')
		}
	}
	if os.write_entire_file(path, strings.to_string(b)) != nil {
		fmt.eprintln("mutate_annotate: cannot write", path)
		return
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
