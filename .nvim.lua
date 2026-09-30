local root = vim.fs.root(0, ".git")
if not root then
  return
end

local function configure()
  vim.opt_local.makeprg = "cd " .. vim.fn.shellescape(root) .. " && odin build src -error-pos-style:unix"
  vim.opt_local.errorformat = "%f:%l:%c: %t%*[^:]: %m,%-G%.%#"
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "odin",
  callback = configure,
})

configure()
