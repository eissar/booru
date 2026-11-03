# Mutation testing with mull (spike)

Put `// mull-on` on the line above a top-level proc and run:

    task mutate -- src/cli

`test/tools/mutate.pl` mutates only the marked procs, runs the package's
`odin test` binary once per mutant, and prints the mutants the tests did not
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
2. Run `odin build -build-mode:test -show-system-calls` to capture the link
   line, then `odin test -build-mode:llvm-ir -debug` to get one `.ll` file per
   module.
3. Compile each `.ll` with `clang -fpass-plugin=mull-ir-frontend-21`.
   `mull.yml` sets `includePaths` to the annotated files and turns off junk
   detection, which tries to parse the source as C++.
4. Link with the captured flags and run `mull-runner --include-not-covered`.

## Example: `src/cli`

`resolve_listen_mode` is marked. The existing tests
`socket_with_port_rejected` and `port_defaults_without_socket` cover it, and
`task mutate -- src/cli -- --ide-reporter-show-killed` reports:

    src/cli/cli.odin:49:2: warning: Killed: Replaced with == [cxx_ne_to_eq]
    src/cli/cli.odin:52:2: warning: Killed: Replaced with != [cxx_eq_to_ne]
    src/cli/cli.odin:52:2: warning: Killed: Replaced with == [cxx_ne_to_eq]
    [info] Mutation score: 100%

Each `if` holds two comparisons, but mull reports one mutant per statement
and mutator (see Limitations).

`check_valid_port` in the same file is not marked. No test calls it, so Odin
leaves it out of the test binary, and marking it would produce no mutants.

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
  `check_valid_port` above).
- **Whole binary.** Each mutant runs the full package test binary. That is fast
  for `src/cli` (under 20 ms total). Slower packages will need their tests split up.
- Linux only. `-show-system-calls` output parsing assumes Odin's clang link
  line.
