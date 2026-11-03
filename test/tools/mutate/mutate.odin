// Mutation-test the procs listed in test/tools/mutate.json (`task mutate`).
//
//     odin run test/tools/mutate -- [-v]     // -v also lists killed mutants
//
// mutate.json is flat JSON: `build` (odin build arguments for the test
// binary), `procs` ("file:proc" to mutate) and `accept` (keys of surviving
// mutants judged equivalent, as printed after each survivor).
//
// ast-grep, with the tree-sitter-odin grammar in .test-data/odin.so (built by
// `task mutate:grammar`), runs test/tools/mutants.yml: `body` finds every
// proc's block, and every other rule's fixes inside a listed block are the
// mutants. Each listed body is rewritten to switch between them:
//
//     name :: proc(...) -> ... {
//     if __mut == 1 {<block with mutant 1>} else if __mut == 2 {...}
//     else {<original block>}
//     }
//
// plus a file per package that sets __mut from $MUTANT at startup. The
// rewritten files reach the compiler through `-overlay`, so the worktree is
// never written. The suite is built once and run once per mutant; mutants
// that do not compile are dropped by the compiler's error lines.
package mutate

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Config :: struct {
	build:  []string,
	procs:  []string,
	accept: []string,
}

// A listed proc's block, braces included, as byte offsets into its file.
Body :: struct {
	file, name: string,
	start, end: int,
}

// One edit inside a body: replace [start, end) with `new`.
Mutant :: struct {
	id, body:   int, // body indexes `bodies`
	file:       string,
	rule, new:  string,
	start, end: int,
	dropped:    bool,
}

Line :: struct {
	file: string,
	line: int,
}

work: string
config: Config
src: map[string]string // file -> contents
bodies: [dynamic]Body
mutants: [dynamic]Mutant

fail :: proc(args: ..any) -> ! {
	fmt.eprintln(..args)
	os.exit(1)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {fail("mutate:", path, err)}
	return string(data)
}

write :: proc(path, text: string) {
	if err := os.write_entire_file(path, text); err != nil {fail("mutate:", path, err)}
}

// Run a command; return its combined output and whether it succeeded.
run :: proc(cmd: ..string) -> (output: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = cmd}, context.allocator)
	if err != nil {fail("mutate:", cmd[0], err)}
	return cat(string(stdout), string(stderr)), state.exit_code == 0
}

// Listed bodies and their mutants, as byte ranges, from `ast-grep scan`.
scan :: proc() {
	grammar := cat(os.get_working_directory(context.allocator) or_else ".", "/.test-data/odin.so")
	if !os.exists(grammar) {fail("mutate: missing", grammar, "- run `task mutate:grammar`")}
	sg_config := cat(work, "/sgconfig.yml")
	write(
		sg_config,
		cat(
			"customLanguages:\n  odin:\n    libraryPath: ",
			grammar,
			"\n    extensions: [odin]\n    expandoChar: _\n",
		),
	)
	sg := os.get_env("AST_GREP", context.allocator)
	if sg == "" {sg = "ast-grep"}
	out, ok := run(
		sg,
		"scan",
		"--config",
		sg_config,
		"--custom-languages",
		"allow",
		"--rule",
		"test/tools/mutants.yml",
		"--json=stream",
		"src",
	)
	if !ok {fail(out, "\nmutate: ast-grep scan failed")}

	offsets :: proc(v: json.Value) -> (int, int) {
		o := v.(json.Object)
		return int(o["start"].(json.Integer)), int(o["end"].(json.Integer))
	}
	seen: map[string]bool
	fixes: [dynamic]Mutant
	for line in strings.split_lines(out) {
		if line == "" {continue}
		v, err := json.parse_string(line, parse_integers = true)
		if err != nil {fail("mutate: bad ast-grep output:", line)}
		m := v.(json.Object)
		file, rule := m["file"].(json.String), m["ruleId"].(json.String)
		if file not_in src {src[file] = read(file)}
		start, end := offsets(m["range"].(json.Object)["byteOffset"])
		if rule == "body" {
			name := proc_name(src[file][:start])
			if slice.contains(config.procs, cat(file, ":", name)) {
				append(&bodies, Body{file, name, start, end})
			}
		} else if new, has := m["replacement"].(json.String); has {
			if r, has_r := m["replacementOffsets"]; has_r {start, end = offsets(r)}
			key := fmt.aprintf("%s %d %d %s", file, start, end, new)
			if !seen[key] {
				seen[key] = true
				append(
					&fixes,
					Mutant{file = file, rule = rule, new = new, start = start, end = end},
				)
			}
		}
	}
	for p in config.procs {
		found := false
		for b in bodies {found ||= cat(b.file, ":", b.name) == p}
		if !found {fail("mutate: mutate.json lists", p, "but no such proc was found")}
	}

	// Keep fixes inside a listed body, ordered by position.
	slice.sort_by(bodies[:], proc(a, b: Body) -> bool {
		return a.file < b.file || a.file == b.file && a.start < b.start
	})
	for f in fixes {
		for b, i in bodies {
			if b.file == f.file && b.start <= f.start && f.end <= b.end {
				m := f
				m.body = i
				append(&mutants, m)
			}
		}
	}
	slice.sort_by(mutants[:], proc(a, b: Mutant) -> bool {
		return a.body < b.body || a.body == b.body && a.start < b.start
	})
	for &m, i in mutants {m.id = i + 1}
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

// Write the switched bodies under work/ and an overlay mapping them over the
// real files. Returns, for each rewritten line, the mutant it belongs to.
write_overlay :: proc() -> (overlay: string, where_: map[Line]int) {
	cwd, _ := os.get_working_directory(context.allocator)
	replace: map[string]string
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
		for body, bi in bodies {
			if body.file != file {continue}
			emit(&b, &line, text[at:body.start])
			block := text[body.start:body.end]
			prev := 0
			for m in mutants {
				if m.dropped || m.body != bi {continue}
				mutated := cat(block[:m.start - body.start], m.new, block[m.end - body.start:])
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

		flat, _ := strings.replace_all(file, "/", "_")
		rewritten := cat(work, "/", flat)
		write(rewritten, strings.to_string(b))
		replace[cat(cwd, "/", file)] = rewritten

		pkg := "?"
		for l in strings.split_lines(text) {
			if strings.has_prefix(l, "package ") {pkg = strings.trim_space(l[8:]); break}
		}
		switch_file := cat(work, "/", flat, ".switch.odin")
		write(switch_file, cat("package ", pkg, SWITCH))
		replace[cat(cwd, "/", filepath.dir(file), "/zz_mutate_switch.odin")] = switch_file
	}
	data, _ := json.marshal(struct {
		Replace: map[string]string,
	}{replace})
	overlay = cat(work, "/overlay.json")
	write(overlay, string(data))
	return
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

// Build; on errors, drop the mutants whose lines they point at and retry.
build :: proc(exe: string) {
	cwd, _ := os.get_working_directory(context.allocator)
	for round := 1;; round += 1 {
		overlay, where_ := write_overlay()
		cmd := slice.concatenate(
			[][]string {
				{"odin", "build"},
				config.build,
				{
					"-error-pos-style:unix",
					"-max-error-count:10000",
					cat("-overlay:", overlay),
					cat("-out:", exe),
				},
			},
		)
		out, ok := run(..cmd)
		if ok {return}
		bad: map[int]bool
		for l in strings.split_lines(out) {
			// path:line:col: [Syntax ]Error: ...
			if strings.has_prefix(l, "\t") || !strings.contains(l, "Error") {continue}
			i := strings.index(l, ".odin:")
			if i < 0 {continue}
			file := strings.trim_prefix(l[:i + 5], cat(cwd, "/"))
			rest := l[i + 6:]
			n, _ := strconv.parse_int(rest[:strings.index_byte(rest, ':')])
			id, found := where_[{file, n}]
			if !found {fail(out, fmt.tprintf("mutate: build error outside any mutant (%s:%d)", file, n))}
			bad[id] = true
		}
		if len(bad) == 0 {fail(out, "mutate: build failed")}
		live := 0
		for &m in mutants {
			m.dropped ||= bad[m.id]
			if !m.dropped {live += 1}
		}
		fmt.eprintfln("mutate: round %d dropped %d mutants that do not compile", round, len(bad))
		if live == 0 {fail("mutate: every mutant failed to compile")}
	}
}

// Run the suite with $MUTANT set; true if it passed within the timeout.
passes :: proc(exe: string, id: int, timeout: time.Duration) -> bool {
	env, _ := os.environ(context.allocator)
	env = slice.concatenate([][]string{env, {fmt.aprintf("MUTANT=%d", id)}})
	p, err := os.process_start({command = {exe}, env = env})
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
	return cat(b.file, ":", b.name, ":", m.rule, ":", squash(src[b.file][m.start:m.end]))
}

show :: proc(status: string, m: Mutant) {
	file := bodies[m.body].file
	before := src[file][:m.start]
	line := strings.count(before, "\n") + 1
	col := m.start - strings.last_index_byte(before, '\n')
	orig := squash(src[file][m.start:m.end])
	if len(orig) > 63 {orig = cat(orig[:60], "...")}
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
	root, _ := filepath.clean(cat(#directory, "/../../.."), context.allocator)
	if err := os.change_directory(root); err != nil {fail("mutate: chdir", root, err)}
	if err := json.unmarshal(transmute([]byte)read("test/tools/mutate.json"), &config, .JSON);
	   err != nil {
		fail("mutate: test/tools/mutate.json:", err)
	}
	err: os.Error
	work, err = os.make_directory_temp("", "booru-mutate-*", context.allocator)
	if err != nil {fail("mutate: temp dir:", err)}

	scan()
	names: [dynamic]string
	for b in bodies {append(&names, b.name)}
	fmt.eprintfln(
		"mutate: %d mutants in %s (%s)",
		len(mutants),
		strings.join(names[:], ", "),
		work,
	)
	exe := cat(work, "/test")
	build(exe)

	// Baseline, then one run per mutant. A failing or timed-out run kills it.
	t0 := time.now()
	if !passes(exe, 0, os.TIMEOUT_INFINITE) {fail("mutate: the suite fails without mutants")}
	timeout := 10 * (time.since(t0) + time.Second)
	killed, accepted, missed: [dynamic]Mutant
	used: map[string]bool
	for m in mutants {
		if m.dropped {continue}
		if !passes(exe, m.id, timeout) {append(&killed, m); continue}
		key := accept_key(m)
		if slice.contains(
			config.accept,
			key,
		) {used[key] = true; append(&accepted, m)} else {append(&missed, m)}
	}

	if verbose {
		for m in killed {show("killed", m)}
		for m in accepted {show("accepted", m)}
	}
	for m in missed {
		show("SURVIVED", m)
		fmt.printfln("    accept key: %s", accept_key(m))
	}
	for key in config.accept {
		if !used[key] {fmt.eprintln("mutate: accept entry matched no surviving mutant:", key)}
	}
	total := len(killed) + len(accepted) + len(missed)
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
