if vim.g.loaded_nvim_zh == 1 then return end
vim.g.loaded_nvim_zh = 1

vim.api.nvim_create_user_command('NvimZh', function()
  local _, err = require('nvim-zh').open()
  if err then vim.notify(err, vim.log.levels.WARN) end
end, { desc = '打开 nvim-zh 只读中文状态面板' })

vim.api.nvim_create_user_command('NvimZhCheck', function()
  require('nvim-zh.health').show()
end, { desc = '只读检查 nvim-zh 的原生环境和支持资源' })
