// Mutation-test the procs listed in test/tools/mutate.json.
//
//     odin run test/tools/mutate -- [-v]     // -v also lists killed mutants
//
// MUTATE_DEBUG=1 prints the compiler output of each round.
//
// mutate.json is flat JSON: `build` (odin build arguments for the test
// binary), `procs` ("file:proc" to mutate) and `accept` (keys of surviving
// mutants judged equivalent, as printed after each survivor).
//
// ast-grep (with the tree-sitter-odin grammar) runs the rules in
// test/tools/mutants.yml: `body` finds every proc's block, and every other
// rule's matches with their fixes inside a listed proc's block are the
// mutants. Instead of rebuilding per mutant, every mutant becomes a branch of
// the body:
//
//     name :: proc(...) -> ... {
//     if __mut == 1 {<block with mutant 1>} else if __mut == 2 {...}
//     else {<original block>}
//     }
//
// and a generated file per package sets __mut from $MUTANT at startup. The
// suite is built once and run once per mutant. Mutants that do not compile
// are dropped using the compiler's error lines. The worktree is never
// written.
package mutate

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

GRAMMAR_REPO :: "https://github.com/tree-sitter-grammars/tree-sitter-odin"
GRAMMAR_REV :: "d2ca8efb4487e156a60d5bd6db2598b872629403"

Config :: struct {
	build:  []string,
	procs:  []string,
	accept: []string,
}

// A listed proc's block, braces included, as byte offsets into its file.
Body :: struct {
	file:       string,
	name:       string,
	start, end: int,
}

// One edit inside a body: replace [start, end) with `new`.
Mutant :: struct {
	id:         int,
	body:       int, // index into bodies
	rule:       string,
	start, end: int,
	new:        string,
	dropped:    bool,
}

Line :: struct {
	file: string,
	line: int,
}

root, work, tree: string
config: Config
src: map[string]string // file -> contents
bodies: [dynamic]Body
mutants: [dynamic]Mutant

fail :: proc(args: ..any) -> ! {
	fmt.eprintln(..args)
	os.exit(1)
}

read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {fail("mutate:", path, err)}
	return string(data)
}

write :: proc(path, text: string) {
	if err := os.write_entire_file(path, text); err != nil {fail("mutate:", path, err)}
}

// Run a command and return its combined output and whether it succeeded.
run :: proc(cmd: []string, dir := "") -> (output: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec(
		{command = cmd, working_dir = dir},
		context.allocator,
	)
	if err != nil {fail("mutate:", cmd[0], err)}
	return strings.concatenate({string(stdout), string(stderr)}), state.exit_code == 0
}

sh :: proc(script: string, dir := "") -> bool {
	_, ok := run({"sh", "-c", script}, dir)
	return ok
}

find_ast_grep :: proc() -> string {
	candidates := [dynamic]string{}
	if p, ok := os.lookup_env("AST_GREP", context.allocator); ok {append(&candidates, p)}
	append(&candidates, "/tmp/sgvenv/bin/ast-grep")
	for dir in strings.split(os.get_env("PATH", context.allocator), ":") {
		append(&candidates, strings.concatenate({dir, "/ast-grep"}))
	}
	for c in candidates {
		if os.is_file(c) {return c}
	}
	fail("mutate: ast-grep not found; see test/tools/MUTATION.md")
}

// The Odin grammar, built once into .test-data/ (gitignored).
ensure_grammar :: proc() -> string {
	grammar := strings.concatenate({root, "/.test-data/odin.so"})
	if os.exists(grammar) {return grammar}
	dir := strings.concatenate({root, "/.test-data/tree-sitter-odin"})
	fmt.eprintln("mutate: building", grammar)
	script := fmt.aprintf(
		"rm -rf '%s' && git init -q '%s' && git -C '%s' fetch -q --depth 1 '%s' %s" +
		" && git -C '%s' checkout -q FETCH_HEAD" +
		" && cc -shared -fPIC -O2 -I'%s/src' '%s/src/parser.c' '%s/src/scanner.c' -o '%s'",
		dir,
		dir,
		dir,
		GRAMMAR_REPO,
		GRAMMAR_REV,
		dir,
		dir,
		dir,
		dir,
		grammar,
	)
	if !sh(script) {fail("mutate: could not build the tree-sitter-odin grammar")}
	return grammar
}

// 1. Marked blocks and mutants from `ast-grep scan`, as byte ranges.
scan :: proc(sg, grammar: string) {
	sg_config := strings.concatenate({work, "/sgconfig.yml"})
	write(
		sg_config,
		strings.concatenate(
			{
				"customLanguages:\n  odin:\n    libraryPath: ",
				grammar,
				"\n    extensions: [odin]\n    expandoChar: _\n",
			},
		),
	)
	rules := strings.concatenate({root, "/test/tools/mutants.yml"})
	out, ok := run(
		{
			sg,
			"scan",
			"--config",
			sg_config,
			"--custom-languages",
			"allow",
			"--rule",
			rules,
			"--json=stream",
			"src",
		},
		tree,
	)
	if !ok {fail(out, "\nmutate: ast-grep scan failed")}

	Match :: struct {
		file, rule, new: string,
		start, end:      int,
	}
	matches: [dynamic]Match
	for line in strings.split_lines(out) {
		if line == "" {continue}
		v, err := json.parse_string(line, parse_integers = true)
		if err != nil {fail("mutate: bad ast-grep output:", line)}
		m := v.(json.Object)
		file := m["file"].(json.String)
		rule := m["ruleId"].(json.String)
		at := m["range"].(json.Object)["byteOffset"].(json.Object)
		if file not_in src {src[file] = read(strings.concatenate({tree, "/", file}))}
		start, end := int(at["start"].(json.Integer)), int(at["end"].(json.Integer))
		if rule == "body" {
			name := proc_name(src[file][:start])
			if slice.contains(config.procs, strings.concatenate({file, ":", name})) {
				append(&bodies, Body{file, name, start, end})
			}
		} else if new, has := m["replacement"].(json.String); has {
			if r, has_r := m["replacementOffsets"].(json.Object); has_r {
				start, end = int(r["start"].(json.Integer)), int(r["end"].(json.Integer))
			}
			append(&matches, Match{file, rule, new, start, end})
		}
	}
	for p in config.procs {
		found := false
		for b in bodies {found ||= strings.concatenate({b.file, ":", b.name}) == p}
		if !found {fail("mutate: mutate.json lists", p, "but no such proc was found")}
	}
	if len(bodies) == 0 {fail("mutate: mutate.json lists no procs")}

	slice.sort_by(matches[:], proc(a, b: Match) -> bool {
		return a.file < b.file || a.file == b.file && a.start < b.start
	})
	seen: map[string]bool
	for m in matches {
		body := -1
		for b, i in bodies {
			if b.file == m.file && b.start <= m.start && m.end <= b.end {body = i}
		}
		if body < 0 {continue}
		key := fmt.aprintf("%s %d %d %s", m.file, m.start, m.end, m.new)
		if seen[key] {continue}
		seen[key] = true
		append(
			&mutants,
			Mutant {
				id = len(mutants) + 1,
				body = body,
				rule = m.rule,
				start = m.start,
				end = m.end,
				new = m.new,
			},
		)
	}
}

// Name of the last top-level `name :: proc` in text.
proc_name :: proc(text: string) -> (name: string) {
	name = "?"
	for line in strings.split_lines(text) {
		i := strings.index(line, " :: proc")
		if i > 0 && !strings.contains_any(line[:i], " \t") {name = line[:i]}
	}
	return
}

// 3. Write the switched bodies into the scratch tree. Returns, for each line
// of the rewritten files, the mutant whose branch it belongs to.
write_tree :: proc() -> map[Line]int {
	where_ := make(map[Line]int)
	files: map[string]bool
	for b in bodies {files[b.file] = true}
	for file in files {
		text := src[file]
		b := strings.builder_make()
		line := 1
		emit :: proc(b: ^strings.Builder, line: ^int, s: string) {
			strings.write_string(b, s)
			line^ += strings.count(s, "\n")
		}
		at := 0
		order: [dynamic]int
		for body, i in bodies {if body.file == file {append(&order, i)}}
		slice.sort_by(order[:], proc(x, y: int) -> bool {return bodies[x].start < bodies[y].start})
		for bi in order {
			body := bodies[bi]
			emit(&b, &line, text[at:body.start])
			block := text[body.start:body.end]
			prev := 0
			for m in mutants {
				if m.dropped || m.body != bi {continue}
				mutated := strings.concatenate(
					{block[:m.start - body.start], m.new, block[m.end - body.start:]},
				)
				first := line
				emit(&b, &line, prev != 0 ? " else " : "{\n")
				emit(&b, &line, fmt.aprintf("if __mut == %d %s", m.id, mutated))
				for l in first ..= line {where_[{file, l}] = m.id}
				prev = m.id
			}
			if prev != 0 {
				emit(&b, &line, " else ")
				where_[{file, line}] = prev // a brace a mutant broke shows up here
			}
			emit(&b, &line, block)
			if prev != 0 {emit(&b, &line, "\n}")}
			at = body.end
		}
		emit(&b, &line, text[at:])
		write(strings.concatenate({tree, "/", file}), strings.to_string(b))

		pkg := "?"
		for l in strings.split_lines(text) {
			if strings.has_prefix(
				l,
				"package ",
			) {pkg = strings.trim_space(l[len("package "):]); break}
		}
		write(
			strings.concatenate({tree, "/", filepath.dir(file), "/zz_mutate_switch.odin"}),
			strings.concatenate({"package ", pkg, SWITCH}),
		)
	}
	return where_
}

// Appended to `package <name>`; not a format string (it has braces).
SWITCH :: `

import __mutate_rt "base:runtime"
import __mutate_os "core:os"
import __mutate_strconv "core:strconv"

@(private = "package")
__mut: int

@(init, private = "file")
__mutate_init :: proc "contextless" () {
	context = __mutate_rt.default_context()
	buf: [32]u8
	__mut, _ = __mutate_strconv.parse_int(__mutate_os.get_env(buf[:], "MUTANT"))
}
`

live :: proc() -> (n: int) {
	for m in mutants {if !m.dropped {n += 1}}
	return
}

// Build; on errors, drop the mutants whose lines they point at and retry.
build :: proc(exe: string) {
	cmd := slice.concatenate(
		[][]string {
			{"odin", "build"},
			config.build,
			{
				"-error-pos-style:unix",
				"-max-error-count:10000",
				strings.concatenate({"-out:", exe}),
			},
		},
	)
	for round := 1;; round += 1 {
		where_ := write_tree()
		out, ok := run(cmd, tree)
		if ok {return}
		if os.get_env("MUTATE_DEBUG", context.allocator) != "" {fmt.eprint(out)}
		bad: map[int]bool
		for l in strings.split_lines(out) {
			// path:line:col: [Syntax ]Error: ...
			if strings.has_prefix(l, "\t") || !strings.contains(l, "Error") {continue}
			i := strings.index(l, ".odin:")
			if i < 0 {continue}
			file := strings.trim_prefix(l[:i + len(".odin")], strings.concatenate({tree, "/"}))
			rest := l[i + len(".odin:"):]
			n, _ := strconv.parse_int(rest[:strings.index_byte(rest, ':')])
			id, found := where_[{file, n}]
			if !found {fail(out, fmt.tprintf("\nmutate: build error outside any mutant (%s:%d)", file, n))}
			bad[id] = true
		}
		if len(bad) == 0 {fail(out, "\nmutate: build failed")}
		for &m in mutants {if bad[m.id] {m.dropped = true}}
		fmt.eprintfln("mutate: round %d dropped %d mutants that do not compile", round, len(bad))
		if live() == 0 {fail("mutate: every mutant failed to compile")}
	}
}

// Run the suite with $MUTANT set; true if it passed within the timeout.
passes :: proc(exe: string, id: int, timeout: time.Duration) -> bool {
	env, _ := os.environ(context.allocator)
	env2 := slice.concatenate([][]string{env, {fmt.aprintf("MUTANT=%d", id)}})
	p, err := os.process_start({command = {exe}, env = env2, working_dir = tree})
	if err != nil {fail("mutate:", exe, err)}
	state, _ := os.process_wait(p, timeout)
	if !state.exited {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return false
	}
	return state.exit_code == 0
}

squash :: proc(s: string) -> string {
	return strings.join(strings.fields(s), " ")
}

// Line-independent name for `accept`: file:proc:rule:original text.
accept_key :: proc(m: Mutant) -> string {
	b := bodies[m.body]
	return strings.concatenate(
		{b.file, ":", b.name, ":", m.rule, ":", squash(src[b.file][m.start:m.end])},
	)
}

show :: proc(status: string, m: Mutant) {
	file := bodies[m.body].file
	text := src[file]
	before := text[:m.start]
	line := strings.count(before, "\n") + 1
	col := m.start - (strings.last_index_byte(before, '\n') + 1) + 1
	orig := squash(text[m.start:m.end])
	if len(orig) > 63 {orig = strings.concatenate({orig[:60], "..."})}
	fmt.printfln(
		"%s:%d:%d: %s: [%s] `%s` => `%s`",
		file,
		line,
		col,
		status,
		m.rule,
		orig,
		squash(m.new),
	)
}

main :: proc() {
	verbose := len(os.args) > 1 && os.args[1] == "-v"
	root, _ = filepath.clean(strings.concatenate({#directory, "/../../.."}), context.allocator)
	if err := os.change_directory(root); err != nil {fail("mutate: chdir", root, err)}
	data, read_err := os.read_entire_file("test/tools/mutate.json", context.allocator)
	if read_err != nil {fail("mutate: test/tools/mutate.json:", read_err)}
	if err := json.unmarshal(data, &config, .JSON); err != nil {
		fail("mutate: test/tools/mutate.json:", err)
	}
	sg := find_ast_grep()
	grammar := ensure_grammar()

	err: os.Error
	work, err = os.make_directory_temp("", "booru-mutate-*", context.allocator)
	if err != nil {fail("mutate: temp dir:", err)}
	tree = strings.concatenate({work, "/tree"})
	fmt.eprintln("mutate: scratch dir", work)
	copy := fmt.aprintf(
		"git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- . '%s'",
		tree,
	)
	if !sh(copy) {fail("mutate: copy failed")}

	scan(sg, grammar)
	names: [dynamic]string
	for b in bodies {append(&names, b.name)}
	fmt.eprintfln("mutate: %d mutants in %s", len(mutants), strings.join(names[:], ", "))

	exe := strings.concatenate({work, "/test-all"})
	build(exe)

	// Baseline, then one run per mutant. A failing or timed-out run kills it.
	t0 := time.now()
	if !passes(exe, 0, os.TIMEOUT_INFINITE) {fail("mutate: test:all fails without mutants")}
	timeout := 10 * (time.since(t0) + time.Second)
	survived, killed: [dynamic]Mutant
	for m in mutants {
		if m.dropped {continue}
		append(passes(exe, m.id, timeout) ? &survived : &killed, m)
	}

	by_pos :: proc(a, b: Mutant) -> bool {
		fa, fb := bodies[a.body].file, bodies[b.body].file
		return fa < fb || fa == fb && (a.start < b.start || a.start == b.start && a.id < b.id)
	}
	slice.sort_by(killed[:], by_pos)
	slice.sort_by(survived[:], by_pos)
	if verbose {for m in killed {show("killed", m)}}
	accepted, missed: [dynamic]Mutant
	used: map[string]bool
	for m in survived {
		key := accept_key(m)
		if slice.contains(config.accept, key) {
			used[key] = true
			append(&accepted, m)
		} else {
			append(&missed, m)
		}
	}
	if verbose {for m in accepted {show("accepted", m)}}
	for m in missed {
		show("SURVIVED", m)
		fmt.printfln("    accept key: %s", accept_key(m))
	}
	for key in config.accept {
		if !used[key] {fmt.eprintln("mutate: accept entry matched no surviving mutant:", key)}
	}
	total := len(killed) + len(survived)
	fmt.printfln(
		"mutate: %d/%d killed (%.0f%%), %d accepted, %d missed",
		len(killed),
		total,
		100 * f64(len(killed)) / f64(total),
		len(accepted),
		len(missed),
	)
	os.exit(len(missed) > 0 ? 1 : 0)
}
