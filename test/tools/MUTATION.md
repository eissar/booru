# Mutation testing (spike)

    task mutate          # survivors and score; exits 1 on unaccepted survivors
    task mutate -- -v    # also list killed and accepted mutants

`test/tools/mutate/` makes small edits ("mutants") to the procs listed in
`test/tools/mutate.json`, runs the test suite once per mutant, and reports
the edits no test noticed.

Needs [ast-grep](https://ast-grep.github.io/) on `PATH` or in `AST_GREP`
(e.g. `python3 -m venv /tmp/sgvenv && /tmp/sgvenv/bin/pip install ast-grep-cli`).
`task mutate:grammar` (run by `task mutate`) builds the pinned
tree-sitter-odin grammar into `.test-data/odin.so` with `git` and `cc`.

## Config: `test/tools/mutate.json`

Flat JSON, read with `json.unmarshal` (strict `.JSON`):

- `build`: `odin build` arguments for the test binary (here, `test:all`).
- `procs`: `file:proc` to mutate. An entry matching no proc is an error.
  Only list procs the suite reaches; `test/test-all.odin` decides which
  packages' tests are in it (`src/cli`'s are not).
- `accept`: survivors judged equivalent, as `file:proc:rule:original text`
  (no line number). Each unaccepted survivor prints its key; entries
  matching no survivor are reported.

Accepted, and why:

- `validate_tags_xor:eq-to-le:len(tag) == 0`: `len` is never negative, so
  `<= 0` is the same check as `== 0`.

## How it works

1. `ast-grep scan` runs `test/tools/mutants.yml`. `body` finds every proc's
   block; the listed ones are kept. Every other rule is a pattern plus a
   `fix`, and each match inside a kept block is a mutant named by the rule
   id. Rules cover operator swaps, `!x`/`-x` → `x`, `if` conditions →
   `true`/`false`, deleting calls and assignments, and replacing the whole
   body with `{}`, `return {}` or a bare `return`. Add a mutation by adding
   a rule.
2. Each kept body becomes one branch per mutant,
   `{if __mut == 1 {...} else if __mut == 2 {...} else {<original>}}`, and a
   generated `zz_mutate_switch.odin` per package sets `__mut` from `$MUTANT`.
   These files reach the compiler through `-overlay`; the worktree is never
   written.
3. Build once. Mutants that do not compile are dropped by mapping the
   compiler's error lines to their branch, then the build is retried.
4. Run with `MUTANT=0` (must pass), then once per mutant with a timeout of
   ten times that. A failing or timed-out run kills the mutant.

On `validate_tags_xor`: 14 mutants, 13 killed, 1 accepted, about 4 s.

## Limitations

- Equivalent mutants must be judged by hand and accepted.
- Procs with unnamed multiple results (`-> (int, bool)`) get no whole-body
  mutant; tree-sitter-odin does not parse that result list.
- Each mutant copies the whole body, so code size grows with mutants × body
  length.
- Mutants run one at a time.
- tree-sitter-odin is a community grammar; syntax it does not know can hide
  bodies or sites.
