// Closes the `// mull-on` regions written in Odin sources, so mull only
// mutates the decl that follows each marker.
//
// Usage: odin run test/tools/mutate_annotate.odin -file -- <table> <file.odin>...
//
// In the source, put `// mull-on` on the line above a top-level decl. Run this
// on a scratch copy of the tree, never on the worktree: it appends
// `// mull-off` to the package line and to the line after each marked decl.
// Appending keeps line numbers stable, so mull's reports still point at the
// right place. Every file with at least one marker is printed to stdout;
// other files are left alone.
//
// It also writes <table>: one line per source line of each marked proc,
//
//     <file>\t<line>\t<op classes, comma-separated>
//
// naming the operator tokens on that line. Odin's debug info does not point
// at operators (an instruction gets its statement's, or a nearby, line and
// column), so mutate.pl uses this table to drop mutants on IR operators whose
// line has no source operator that lowers to them, such as the UTF-8
// decoding in `for c in str`. This plays the part of mull's junk detection,
// which only parses C and C++.
package mutate_annotate

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"

MARKER :: "mull-on"

decl_start :: proc(decl: ^ast.Stmt) -> int {
	if vd, ok := decl.derived.(^ast.Value_Decl); ok && len(vd.attributes) > 0 {
		return vd.attributes[0].pos.line
	}
	return decl.pos.line
}

// What an operator can lower to; mutate.pl maps IR opcodes onto the same
// names (the enum names, lowercased).
Op :: enum {
	Cmp,
	Add,
	Sub,
	Mul,
	Div,
	Rem,
	And,
	Or,
	Xor,
	Shl,
	Shr,
}
Ops :: bit_set[Op]

op_classes :: proc(kind: tokenizer.Token_Kind) -> Ops {
	#partial switch kind {
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_And, .Cmp_Or, .Cmp_And_Eq, .Cmp_Or_Eq:
		return {.Cmp}
	case .Not:
		return {.Cmp, .Xor}
	case .Add, .Add_Eq:
		return {.Add}
	case .Sub, .Sub_Eq:
		return {.Sub}
	case .Mul, .Mul_Eq:
		return {.Mul}
	case .Quo, .Quo_Eq:
		return {.Div}
	case .Mod, .Mod_Mod, .Mod_Eq, .Mod_Mod_Eq:
		return {.Rem}
	case .And, .And_Eq:
		return {.And}
	case .Or, .Or_Eq:
		return {.Or}
	case .Xor, .Xor_Eq:
		return {.Xor}
	case .And_Not, .And_Not_Eq:
		return {.And, .Xor}
	case .Shl, .Shl_Eq:
		return {.Shl}
	case .Shr, .Shr_Eq:
		return {.Shr}
	}
	return {}
}

// Append one table line per source line of a marked proc's body, naming the
// classes of the operator tokens on that line.
write_table :: proc(b: ^strings.Builder, path: string, decl: ^ast.Stmt) {
	vd, is_value := decl.derived.(^ast.Value_Decl)
	if !is_value || len(vd.values) != 1 {
		return
	}
	pl, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || pl.body == nil {
		return
	}
	first := pl.body.pos.line
	@(static) lines: []Ops
	@(static) base: int
	lines = make([]Ops, pl.body.end.line - first + 1, context.temp_allocator)
	base = first
	ast.inspect(pl.body, proc(n: ^ast.Node) -> bool {
		if n == nil {
			return false
		}
		op: tokenizer.Token
		#partial switch e in n.derived {
		case ^ast.Binary_Expr:
			op = e.op
		case ^ast.Unary_Expr:
			op = e.op
		case ^ast.Assign_Stmt:
			op = e.op
		case:
			return true
		}
		if i := op.pos.line - base; i >= 0 && i < len(lines) {
			lines[i] += op_classes(op.kind)
		}
		return true
	})
	for ops, i in lines {
		fmt.sbprintf(b, "%s\t%d\t", path, first + i)
		sep := ""
		for o in ops {
			fmt.sbprintf(b, "%s%s", sep, strings.to_lower(fmt.tprint(o), context.temp_allocator))
			sep = ","
		}
		strings.write_byte(b, '\n')
	}
}

annotate :: proc(path: string, table: ^strings.Builder) -> (marked: bool, ok: bool) {
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
			write_table(table, path, next)
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
	if len(os.args) < 2 {
		fmt.eprintln("usage: mutate_annotate <table> <file.odin>...")
		os.exit(2)
	}
	failed := false
	table := strings.builder_make()
	for path in os.args[2:] {
		marked, ok := annotate(path, &table)
		if !ok {
			failed = true
		} else if marked {
			fmt.println(path)
		}
	}
	if os.write_entire_file(os.args[1], strings.to_string(table)) != nil {
		fmt.eprintln("mutate_annotate: cannot write", os.args[1])
		failed = true
	}
	if failed {
		os.exit(1)
	}
}
