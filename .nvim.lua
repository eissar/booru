vim.opt.makeprg = 'task --silent $* -- -error-pos-style:unix'

-- %t captures E/W from "Error:"/"Warning:", which is what colours the
-- quickfix entries. %-G drops everything else, including odin's indented
-- source and caret lines that would otherwise fill the list with junk.
vim.opt.errorformat = '%f:%l:%c: %t%*[^:]: %m,%-G%.%#'
