if vim.g.loaded_nvim_zh == 1 then return end
vim.g.loaded_nvim_zh = 1

vim.api.nvim_create_user_command('NvimZh', function()
  local _, err = require('nvim-zh').open()
  if err then vim.notify(err, vim.log.levels.WARN) end
end, { desc = '打开 nvim-zh 中文面板' })

vim.api.nvim_create_user_command('NvimZhPacks', function(command)
  local ok, err = pcall(require('nvim-zh.pack_commands').run, command)
  if not ok then vim.notify('nvim-zh：' .. tostring(err), vim.log.levels.WARN) end
end, { nargs = '*', bang = true, desc = '管理 nvim-zh 汉化包', complete = function(lead, line)
  return require('nvim-zh.pack_commands').complete(lead, line)
end })

vim.api.nvim_create_user_command('NvimZhRaw', function()
  local text = require('nvim-zh.compiler').raw_text()
  vim.api.nvim_echo({ { text } }, false, {})
end, { desc = '查看当前 quickfix 或 location 条目的原文、错误码和来源' })

vim.api.nvim_create_user_command('NvimZhDiagnosticRaw', function()
  local rows = vim.diagnostic.get(0, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })
  local lines = vim.tbl_map(function(row)
    local raw = vim.tbl_get(row, 'user_data', 'lsp') or row
    return ('[%s · %s] %s'):format(row.source or '?', raw.code or '?', raw.message)
  end, rows)
  vim.api.nvim_echo({ { #lines > 0 and table.concat(lines, '\n') or '当前行没有诊断' } }, false, {})
end, { desc = '查看当前行诊断的原文和错误码' })

vim.api.nvim_create_user_command('NvimZhCheck', function()
  require('nvim-zh.health').show()
end, { desc = '只读检查 nvim-zh 的原生环境和支持资源' })
