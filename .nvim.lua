-- $* is spliced verbatim where it appears; :make adds no implicit `--`.
-- Task's own flags must precede task names, odin's flags must follow Task's
-- `--`, so a delimiter in makeprg itself would fight the task-name argument.
-- The delimiter therefore stays in the invocation:
--
--   :make test            -> task --silent test             "No tests to run."
--   :make test -- -debug  -> task --silent test -- -debug   odin gets -debug
--   :make check -- -o:none
--
-- `:make test -debug` (no `--`) is still wrong: Task parses -debug as its own
-- -d/--dir flag and reports `No Taskfile found at ""`. Always pass odin flags
-- after `--`.
--
-- -error-pos-style:unix is deliberately not forced here: appending it after
-- user args makes odin reject the duplicate flag, and adding a second `--`
-- makes it fail outright. errorformat below matches both layouts instead.
vim.opt.makeprg = 'task --silent $*'

-- %t captures E/W from "Error:"/"Warning:", which is what colours the
-- quickfix entries. %-G drops everything else, including odin's indented
-- source and caret lines that would otherwise fill the list with junk.
-- Both position layouts are matched since we no longer force unix style.
vim.opt.errorformat = table.concat({
  '%f:%l:%c: %t%*[^:]: %m', -- -error-pos-style:unix
  '%f(%l:%c) %t%*[^:]: %m', -- odin default: file(line:col) Error: msg
  '%-G%.%#',
}, ',')
