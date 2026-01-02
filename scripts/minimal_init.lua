local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>"), ":h:h")

-- Add current directory and lua directory to rtp
vim.opt.rtp:append(root)

-- Add mini.nvim to rtp if it exists in deps
local mini_path = root .. "/deps/mini.nvim"
if vim.fn.isdirectory(mini_path) == 1 then vim.opt.rtp:append(mini_path) end

require("mini.test").setup()
