local root = assert(vim.env.NVIM_ZH_ROOT, 'set NVIM_ZH_ROOT to the checkout')
local expected_native = assert(vim.env.NVIM_ZH_PLATFORM_NATIVE, 'set NVIM_ZH_PLATFORM_NATIVE')
vim.opt.runtimepath:prepend(root)

local seen
local function notify(message) seen = message end
vim.notify = notify
local zh = require('nvim-zh')
zh.setup()
if not vim.wait(15000, function()
  local native = zh.status().native
  return native.status == expected_native
end, 50) then
  local status = zh.status()
  error(vim.inspect({ native = status.native, runtime = status.runtime }))
end
local native = zh.status().native

local ok, message = pcall(vim.fn.writefile, { 'probe' }, vim.fn.tempname() .. '/missing/file')
assert(not ok and tostring(message):find('E482:', 1, true), tostring(message))
local error_text = tostring(message)
if expected_native == 'unsupported' then
  assert(not native.active and error_text:find("Can't open file", 1, true), error_text)
else
  assert(native.active and error_text:find('无法打开文件', 1, true), error_text)
end

vim.cmd.help('options')
assert(vim.api.nvim_buf_get_name(0):match('options%.cnx$'), vim.api.nvim_buf_get_name(0))
vim.cmd.help('credits')
assert(vim.api.nvim_buf_get_name(0):match('credits%.txt$'), vim.api.nvim_buf_get_name(0))
vim.notify('No information available')
assert(seen == '没有可用的信息', vim.inspect(seen))
vim.notify('Platform marker (untranslated)')
assert(seen == 'Platform marker (untranslated)', vim.inspect(seen))
zh.teardown()
assert(vim.notify == notify)
print(('PLATFORM_LOCALIZATION=PASS system=%s arch=%s nvim=%s native=%s help=cn,en ui=zh,source')
  :format(vim.uv.os_uname().sysname, vim.uv.os_uname().machine, tostring(vim.version()), native.status))
print('PLATFORM_NATIVE_REASON=' .. tostring(native.reason))
print('PLATFORM_NATIVE_E482=' .. error_text)
