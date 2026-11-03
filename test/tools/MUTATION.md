# Mutation testing (spike)

Put `// mull-on` on the line above a top-level proc and run:

    task mutate          # survivors and score
    task mutate -- -v    # also list killed mutants

`test/tools/mutate/` (an Odin program) makes small source edits ("mutants") to the marked
procs, runs the `test:all` suite once per mutant, and prints the edits no test
noticed. It exits non-zero if any mutant survives.

## Tools

- [ast-grep](https://ast-grep.github.io/) finds the marked bodies and the
  mutation sites. Install it into `/tmp` (or put `ast-grep` on `PATH`, or
  set `AST_GREP`):

      python3 -m venv /tmp/sgvenv && /tmp/sgvenv/bin/pip install ast-grep-cli

- The [tree-sitter-odin](https://github.com/tree-sitter-grammars/tree-sitter-odin)
  grammar, at a pinned commit, is cloned and compiled into
  `.test-data/odin.so` (gitignored) on the first run. That needs `git` and
  `cc`. ast-grep loads it as a custom language with
  `--custom-languages allow`.

The tool also needs `rsync` and `git`; per-mutant timeouts use `core:os` process waits.

## How it works

1. Copy the tracked tree to `/tmp/booru-mutate-*`; nothing in the worktree is
   written.
2. `ast-grep scan` runs `test/tools/mutants.yml`. Its `body` rule reports the
   block of every proc declared right after a `// mull-on` comment. Every
   other rule is a mutation: a pattern plus a `fix`, and each match inside a
   marked block is one mutant, reported under the rule's id. To add a
   mutation, add a rule. The current set:

   | Rules | Mutation |
   |---|---|
   | `eq-to-ne`, `lt-to-le`, `add-to-sub`, `and-to-or`, ... | swap a binary operator (`==` → `!=`/`<=`/`>=`, `<` → `<=`/`>=`, `+` ↔ `-`, `&&` ↔ `\|\|`, ...) |
   | `drop-not`, `drop-neg` | `!x`, `-x` → `x` |
   | `if-true`, `if-false` | replace an `if` condition |
   | `delete-statement` | call, `x = ...` or `x += ...` → `{}` |
   | `body-empty`, `body-return-zero`, `body-return-named` | replace the whole body with `{}`, `return {}`, or a bare `return` (cargo-mutants' "replace with default") |

3. Duplicate edits (same range and text) are dropped.
4. Rewrite each marked proc so its body is one branch per mutant:

       validate_tags_xor :: proc(tags: []string) -> string {
       if __mut == 1 {<block with mutant 1>} else if __mut == 2 {...}
       else {<original block>}
       }

   A generated `zz_mutate_switch.odin` in the package sets `__mut` from
   `$MUTANT` at startup. Every branch is a full copy of the body, so locals,
   `return`, named results and `defer` behave as in the original.
5. Build `test/` the way `task test:all:build` does. A mutant that does not
   compile is dropped by mapping the compiler's error lines back to its
   branch, and the build is retried (`MUTATE_DEBUG=1` prints each round's
   errors). Because sites come from the syntax tree, this is rare.
6. Run the suite with `MUTANT=0` (must pass), then once per mutant with a
   timeout of ten times the baseline. A failing or timed-out run kills the
   mutant.

## Scope: what `test:all` reaches

Only mark procs that `test:all` reaches. `test/test-all.odin` decides which
packages' tests are in the suite; `src/cli` is not one of them. A marked proc
that no test calls has all its mutants survive.

## Example: `validate_tags_xor`

`src/event_log/event_log.odin` marks `validate_tags_xor`. The rules give 14
mutants, all of which compile; `task mutate` reports:

    src/event_log/event_log.odin:148:6: SURVIVED: [eq-to-le] `len(tag) == 0` => `len(tag) <= 0`
    mutate: 13/14 killed (93%)

That is an equivalent mutant: `len` is never negative, so no test can tell
`<= 0` from `== 0`. The whole-body mutant (`return {}`) is killed. The run
takes about 8 s.

## Limitations

- **Equivalent mutants**, like the one above, survive and have to be judged by
  hand.
- **Unnamed multi-result procs** (`-> (int, bool)`) get no whole-body mutant:
  tree-sitter-odin does not parse that result list cleanly.
- **Code size** grows with mutants × body length, since each mutant copies the
  whole body. Fine for small procs.
- **Grammar drift.** tree-sitter-odin is a community grammar; Odin syntax it
  does not know yet can hide sites or bodies.
- **Sequential runs.** Mutants run one at a time; each is a full `test:all`
  run (about 0.1 s here).
