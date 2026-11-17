if vim.g.loaded_nvim_zh == 1 then return end
vim.g.loaded_nvim_zh = 1

vim.api.nvim_create_user_command('NvimZhInfo', function()
  require('nvim-zh').show_info()
end, { desc = '显示 nvim-zh 版本、locale 与帮助配置' })

vim.api.nvim_create_user_command('NvimZhCheck', function()
  require('nvim-zh.health').show()
end, { desc = '只读检查 nvim-zh 的原生环境和支持资源' })

vim.api.nvim_create_user_command('NvimZhMissing', function()
  require('nvim-zh').show_missing()
end, { desc = '显示本地去重、脱敏的缺失翻译与运行时观察统计' })

vim.api.nvim_create_user_command('NvimZhReload', function()
  local count = require('nvim-zh').reload()
  vim.notify(('已重载翻译目录、用户 override 和 UI/插件适配器（%d 个已注册 domain）'):format(count), vim.log.levels.INFO)
end, { desc = '重载翻译目录、用户 override 并安全重建 UI/插件适配器' })
