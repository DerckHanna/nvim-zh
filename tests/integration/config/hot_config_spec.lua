local zh = require('nvim-zh')
local paths = require('nvim-zh.paths')
local uv = vim.uv or vim.loop
local function wait_for(fn, message)
  assert(vim.wait(5000, fn, 20), message .. ': ' .. vim.inspect(zh.status().runtime))
end
local initial_data = uv.fs_stat(paths.data())
local before_env, before_lang = vim.env.LC_ALL, vim.v.lang
assert(zh.status().configured == false)
zh.stats(); zh.missing()
local superseded, checked
zh.check(function(result) superseded = result end)
zh.check(function(result) checked = result end)
assert(superseded and not superseded.ok and superseded.status == 'cancelled'
  and superseded.error_code == 'superseded' and superseded.error and superseded.task_id)
wait_for(function() return checked ~= nil end, 'read-only check timed out')
assert(checked.ok and checked.status == 'degraded' and checked.error_code == nil
  and checked.error == nil and checked.task_id and type(checked.results) == 'table',
  'pre-setup native warnings must be reported as degraded')
assert(uv.fs_stat(paths.data()) == initial_data, 'queries wrote resources')
assert(vim.env.LC_ALL == before_env and vim.v.lang == before_lang)
local win, why = zh.open()
assert(win == nil and why:find('UI', 1, true), 'headless panel did not return an error')
assert(vim.fn.exists(':NvimZh') == 2 and vim.fn.exists(':NvimZhCheck') == 2)
for _, command in ipairs({ 'NvimZhInfo', 'NvimZhMissing', 'NvimZhReload', 'NvimZhUpdate', 'NvimZhRollback' }) do
  assert(vim.fn.exists(':' .. command) == 0, command .. ' must not exist')
end

zh.setup({ modules = { core = { enabled = false }, plugins = { disabled = { 'nvim-tree' } } } })
assert(zh.status().runtime.status == 'ok', vim.inspect(zh.status().runtime))
assert(zh.status().version.active_bundle)
vim.fn.mkdir(vim.fs.dirname(paths.config()), 'p')
vim.cmd.edit(paths.config())
local function save(value)
  local text = type(value) == 'string' and value or vim.json.encode(value)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  vim.cmd.write()
end
save({ schema = 1, modules = { plugins = { disabled = {} } },
  overrides = { ['nvim-ui'] = { [''] = { ['No information available'] = '保存后自动生效' } } } })
wait_for(function() return zh.status().config.overrides['nvim-ui'] ~= nil end, 'configuration was not applied')
assert(#zh.status().config.modules.plugins.disabled == 0, 'empty list did not replace base list')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '保存后自动生效')
save('{"schema":1,"modules":{"ui":{"notify":"invalid"}}}')
wait_for(function() return zh.status().runtime.config_file.status == 'error' end, 'invalid configuration was accepted')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '保存后自动生效',
  'bad configuration replaced last good state')
local generation = zh.status().runtime.generation
save('{"schema":1,"overrides":{"nvim-ui":{"":{"No information available":"' .. string.char(255) .. '"}}}}')
wait_for(function() return zh.status().runtime.generation > generation end, 'invalid UTF-8 was not checked')
assert(zh.status().runtime.config_file.status == 'error')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '保存后自动生效')
save({ schema = 1, overrides = { ['nvim-ui'] = { [''] = { ['No information available'] = '中间保存' } } } })
save({ schema = 1, overrides = { ['nvim-ui'] = { [''] = { ['No information available'] = '最后保存' } } } })
wait_for(function()
  return zh.status().config.overrides['nvim-ui']['']['No information available'] == '最后保存'
end, 'latest save did not win')
uv.fs_unlink(paths.config())
vim.api.nvim_exec_autocmds('FocusGained', {})
wait_for(function() return next(zh.status().config.overrides) == nil end, 'deleted configuration did not restore base')
assert(#zh.status().config.modules.plugins.disabled == 1)
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '没有可用的信息')
local snapshot = zh.status()
snapshot.config.modules.core.enabled = true
assert(not zh.status().config.modules.core.enabled, 'status leaked mutable config')
assert(not pcall(zh.setup, { modules = { ui = { nonexistent = true } } }), 'unknown field accepted')
print('CONFIG_AUTORELOAD_SPEC=PASS save latest_save invalid_file deletion list_replace readonly_api headless check_superseded')
