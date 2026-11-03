# Mutation testing with mull (spike)

Put `// mull-on` on the line above a top-level proc and run:

    task mutate

`test/tools/mutate.pl` mutates only the marked procs, runs the `test:all`
suite once per mutant, and prints the mutants the tests did not
catch, using worktree paths.

## Tools

Mull 0.37 for LLVM 21 is the version that matches Odin's backend
(`odin report` shows `LLVM 21.1.8`). Unpack the Debian packages into `/tmp`:

    /tmp/mull-pkg/usr/lib/mull-ir-frontend-21   # clang pass plugin
    /tmp/mull-deb13/usr/bin/mull-runner         # runner

Set `MULL_PLUGIN` / `MULL_RUNNER` to use other paths. The script also needs
`clang` (21), `rsync`, and `perl`.

## How it works

Mull is built around clang: its IR pass runs inside the compiler, then
`mull-runner` runs the instrumented binary with one mutant enabled at a time.
Odin can emit LLVM IR, so the script does the clang part itself:

1. Copy the tracked tree to `/tmp/booru-mutate-*`. Mull reads `mull-on` /
   `mull-off` comments from the source files that the debug info points to,
   but the source only carries `// mull-on`, which on its own would leave
   everything after it on. In the copy, `mutate_annotate.odin` uses
   `core:odin/parser` to find the decl after each marker and appends
   `// mull-off` to the package line and to the line after that decl. Only
   existing lines change, so line numbers stay the same. It rejects a marker
   inside a decl or with no decl after it. It also writes a table of the
   operator tokens on each line of the marked procs (used in step 3).
2. Build `test/` the way `task test:all:build` does (`-build-mode:test
   -all-packages -debug`), once with `-show-system-calls` to capture the link
   line and once with `-build-mode:llvm-ir` to get one `.ll` file per module.
   Arguments to `task mutate -- ...` go to `mull-runner`.
3. Filter, then compile each `.ll` with
   `clang -fpass-plugin=mull-ir-frontend-21`. `mull.yml` sets `includePaths`
   to the annotated files and turns off mull's junk detection, which tries to
   parse the source as C++. The filter replaces it (next section).
4. Link with the captured flags and run `mull-runner --include-not-covered`.

## Filtering generated code

In C, mull's junk detection parses the source with clang and drops any mutant
whose location is not a real operator. That cannot work for Odin, and Odin's
debug info does not point at operators anyway: an instruction gets the line
and column of its statement, or of whatever Odin was lowering at the time
(a `for` condition, the `=` of an assignment, sometimes a line in a case
body). So mull also mutates code Odin generates: the UTF-8 decoding behind
`for c in str`, range-loop counters, `bool`-to-`i8` checks.

Before the plugin runs, `mutate.pl` maps each IR operator in a marked proc
(`icmp`/`fcmp` → `cmp`, `add`, `sub`, `mul`, `sdiv`/`udiv` → `div`, ...) to its
source line and keeps its debug location only if the table says that line has
an operator that lowers to it (`<` or `!` for `cmp`, `+=` for `add`, and so
on). Mull skips instructions without a location, so the rest are never
mutated. It prints the counts:

    mutate: kept 4 IR operators in marked code, dropped 8 generated ones

The check is per line, not per operator:

- Generated code on a line with a matching real operator is kept, e.g. the
  `bool` checks of `if a > 3 && a != 7`.
- Odin places a `case` value's comparison on a line of that case's body, so a
  `case x < 0:` comparison is dropped unless the body line also compares.

## Scope: what `test:all` reaches

Only mark procs that `test:all` reaches. Odin compiles only the procs reachable
from the test procs, and no optimisation flag changes that (`-debug` already
means `-o:none`). A marked proc that nothing reaches is not compiled and adds
no mutants, so it shows up as a lower mutant count. `test/test-all.odin` decides
which packages' tests are in the suite; `src/cli` is not one of them, so its
procs cannot be mutation-tested this way.

## Example: `validate_tags_xor`

`src/event_log/event_log.odin` marks `validate_tags_xor`. `task mutate --
--ide-reporter-show-killed` reports:

    src/event_log/event_log.odin:148:3: warning: Killed: Replaced with != [cxx_eq_to_ne]
    src/event_log/event_log.odin:148:3: warning: Killed: Replaced with == [cxx_ne_to_eq]
    src/event_log/event_log.odin:150:4: warning: Killed: Replaced with == [cxx_ne_to_eq]
    src/event_log/event_log.odin:155:4: warning: Killed: Replaced with == [cxx_ne_to_eq]
    [info] Mutation score: 100%

These are `len(tag) == 0`, `!is_allowed_tag_char(c)` and `previous == tag`.
Without the filter the run had 20 mutants and 3 survivors, all on
`for c in tag {`: the loop bound, ASCII check and length arithmetic of Odin's
UTF-8 decoding, which no test can kill and which the filter now drops along
with the range-loop counters. The task exits non-zero when mutants survive.

## Limitations

- **No operator columns.** Odin's debug info gives a statement's (or a
  nearby) column, not each operator's. Mull identifies a mutant by
  `mutator:file:line:col`, so `if a != x && b != y` produces a single
  `cxx_ne_to_eq` mutant that flips both comparisons together, and reports
  point at the start of the statement.
- **Generated code** is filtered per line (see Filtering generated code); what
  is left on a line with a real operator still gets mutated.
- **No coverage.** Mull's coverage filter needs clang's
  `-fcoverage-mapping`, which Odin does not emit, so the script passes
  `--include-not-covered`.
- **Unreached procs are not compiled**, so they produce no mutants (see
  Scope above).
- **Whole suite.** Each mutant runs all of `test:all`. The example above takes
  under 0.5 s for 4 mutants, plus a few seconds of build.
- Linux only. `-show-system-calls` output parsing assumes Odin's clang link
  line.
