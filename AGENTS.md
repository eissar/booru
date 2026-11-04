Run `task hooks:install` once per clone;

the pre-commit hook checks staged Odin contents and aborts if formatting changes are needed. It does not modify working files or re-stage them.

- Minimal in-place diffs; no out-of-scope changes. Inline single-use helpers; prefer repetition over abstraction. Be ready to justify every new symbol.
- don't reassign context.allocator unless you have a good reason.
