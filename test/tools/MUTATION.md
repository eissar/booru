# Mutation testing (spike)

Put `// mull-on` on the line above a top-level proc and run:

    task mutate          # survivors and score
    task mutate -- -v    # also list killed mutants

`test/tools/mutate.pl` makes small source edits ("mutants") to the marked
procs, runs the `test:all` suite once per mutant, and prints the edits no test
noticed. It exits non-zero if any mutant survives.

## Tools

[universalmutator](https://github.com/agroce/universalmutator) generates the
mutants. Install it into `/tmp`:

    python3 -m venv /tmp/umvenv && /tmp/umvenv/bin/pip install universalmutator

Set `UNIVERSALMUTATOR` to use another `mutate` binary. The script also needs
`rsync`, `timeout`, and `perl`.

## How it works

1. Copy the tracked tree to `/tmp/booru-mutate-*`; nothing in the worktree is
   written.
2. Find each marked proc's body by text, relying on odinfmt's layout (the
   pre-commit hook enforces it): after `// mull-on` and any `@(...)` lines
   comes `name :: proc`, the body starts after the signature line ending in
   `{`, and ends before the next `}` in column 0.
3. Run universalmutator on the body lines with its `universal.rules`
   (operators, comparisons, constants) plus `test/tools/odin.rules` (delete a
   statement, negate or pin an `if`). Keep mutants that change one body line;
   drop duplicates and ones that delete the final `return`.
4. Rewrite each marked proc so its body is one branch per mutant:

       validate_tags_xor :: proc(tags: []string) -> string {
       if __mut == 1 {
       <body with mutant 1's line>
       } else if __mut == 2 {
       ...
       } else {
       <original body>
       }
       }

   A generated `zz_mutate_switch.odin` in the package sets `__mut` from
   `$MUTANT` at startup. Every branch is a full copy of the body, so locals,
   `return`, named results and `defer` behave as in the original.
5. Build `test/` the way `task test:all:build` does. Mutants that do not
   compile (regex mutations often don't) are dropped by mapping the
   compiler's error lines back to their branch, and the build is retried.
   Syntax errors stop the parser, so this can take one round per bad mutant.
   `MUTATE_DEBUG=1` prints each round's errors.
6. Run the suite with `MUTANT=0` (must pass), then once per mutant with a
   timeout of ten times the baseline. A failing or timed-out run kills the
   mutant.

## Scope: what `test:all` reaches

Only mark procs that `test:all` reaches. `test/test-all.odin` decides which
packages' tests are in the suite; `src/cli` is not one of them. A marked proc
that no test calls has all its mutants survive.

## Example: `validate_tags_xor`

`src/event_log/event_log.odin` marks `validate_tags_xor`. universalmutator
proposes 32 mutants; 6 do not compile, and of the other 26, `task mutate`
reports:

    src/event_log/event_log.odin:148: SURVIVED: if len(tag) == 0 {return "event tag must not be empty"}  =>  if len(tag) <= 0 {return "event tag must not be empty"}
    mutate: 25/26 killed (96%)

The survivor is an equivalent mutant: `len` is never negative, so `<= 0`
and `== 0` behave the same and no test can tell them apart. The run takes
about 5 s.

## Limitations

- **Equivalent mutants**, like the one above, survive and have to be judged by
  hand.
- **One-line mutants only.** universalmutator's rules work on single lines;
  there is no "replace the whole body" mutant.
- **Code size** grows with mutants × body length, since each mutant copies the
  whole body. Fine for small procs.
- **Layout-dependent.** Marked procs must be odinfmt-formatted top-level procs
  with a multi-line body.
- **Sequential runs.** Mutants run one at a time; each is a full `test:all`
  run (about 0.1 s here).
