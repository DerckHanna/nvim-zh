local M = {}
local source = debug.getinfo(1, 'S').source:sub(2)
M.root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
M.root = vim.uv.fs_realpath(M.root) or M.root
function M.data() return vim.fn.stdpath('data') .. '/nvim-zh' end
function M.config() return vim.fn.stdpath('config') .. '/nvim-zh.json' end
return M
