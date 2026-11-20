local M = {}
local source = debug.getinfo(1, 'S').source:sub(2)
M.root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
M.root = vim.uv.fs_realpath(M.root) or M.root

local function standard_path(kind)
  local path = vim.fn.stdpath(kind)
  if vim.fn.has('macunix') == 1 then
    -- macOS exposes private system directories through these aliases.
    -- Keep the normal symlink checks within the resulting user directory.
    local alias = path:match('^(/[^/]+)/')
    if (alias == '/var' or alias == '/tmp' or alias == '/etc')
        and vim.uv.fs_realpath(alias) == '/private' .. alias then
      return '/private' .. path
    end
  end
  return path
end

function M.data() return standard_path('data') .. '/nvim-zh' end
function M.config() return standard_path('config') .. '/nvim-zh.json' end
return M
