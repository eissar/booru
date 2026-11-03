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
   inside a decl or with no decl after it.
2. Build `test/` the way `task test:all:build` does (`-build-mode:test
   -all-packages -debug`), once with `-show-system-calls` to capture the link
   line and once with `-build-mode:llvm-ir` to get one `.ll` file per module.
   Arguments to `task mutate -- ...` go to `mull-runner`.
3. Compile each `.ll` with `clang -fpass-plugin=mull-ir-frontend-21`.
   `mull.yml` sets `includePaths` to the annotated files and turns off junk
   detection, which tries to parse the source as C++.
4. Link with the captured flags and run `mull-runner --include-not-covered`.

## Scope: what `test:all` reaches

Only mark procs that `test:all` reaches. Odin compiles only the procs reachable
from the test procs, and no optimisation flag changes that (`-debug` already
means `-o:none`). A marked proc that nothing reaches is not compiled and adds
no mutants, so it shows up as a lower mutant count. `test/test-all.odin` decides
which packages' tests are in the suite; `src/cli` is not one of them, so its
procs cannot be mutation-tested this way.

## Example: `validate_tags_xor`

`src/event_log/event_log.odin` marks `validate_tags_xor`. `task mutate`
reports 20 mutants, 17 killed:

    src/event_log/event_log.odin:149:3: warning: Survived: Replaced with >= [cxx_lt_to_ge]
    src/event_log/event_log.odin:149:3: warning: Survived: Replaced with <= [cxx_lt_to_le]
    src/event_log/event_log.odin:149:3: warning: Survived: Replaced with + [cxx_sub_to_add]
    [info] Mutation score: 85%

All three survivors are on `for c in tag {`. That line has no `<` or `-` in the
source. In the IR they are the loop bound, the ASCII fast-path check
(`byte < 0x80`) and the remaining-length subtraction of the loop Odin
generates to decode UTF-8 (see Lowering artifacts below), so they are not
obviously missing tests. The
task exits non-zero when mutants survive.

## Limitations

- **Statement-level columns.** Odin's debug info gives a statement's column,
  not each operator's. Mull identifies a mutant by `mutator:file:line:col`, so
  `if a != x && b != y` produces a single `cxx_ne_to_eq` mutant that flips
  both comparisons together. Reports point at the start of the statement.
- **Lowering artifacts.** Odin lowers `bool` through `i8` (`icmp ne i8 %b, 0`),
  so mull also mutates comparisons that are not in the source. Mutants on the
  same statement merge as described above, which hides most of these.
- **No coverage.** Mull's coverage filter needs clang's
  `-fcoverage-mapping`, which Odin does not emit, so the script passes
  `--include-not-covered`.
- **Unreached procs are not compiled**, so they produce no mutants (see
  Scope above).
- **Whole suite.** Each mutant runs all of `test:all`. The example above takes
  about 2 s for 20 mutants on 9 threads, plus a few seconds of build.
- Linux only. `-show-system-calls` output parsing assumes Odin's clang link
  line.
