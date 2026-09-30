local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
root = vim.fn.fnamemodify(root, ":p")

local function configure()
  vim.opt_local.makeprg = "cd " .. vim.fn.shellescape(root) .. " && odin build src -error-pos-style:unix"
  vim.opt_local.errorformat = "%f:%l:%c: %t%*[^:]: %m,%-G%.%#"
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "odin",
  callback = configure,
})

configure()
