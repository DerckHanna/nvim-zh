local zh = require('nvim-zh')
local native = require('nvim-zh.native_backend')
local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Linux' then print('NATIVE_RESTORE_SPEC=SKIP Linux/glibc+LuaJIT required'); return end
ffi.cdef[[char *bindtextdomain(const char *, const char *);]]
local function binding() return ffi.string(ffi.C.bindtextdomain('nvim', nil)) end
local original_binding, original_lang = binding(), vim.v.lang
local original_path, original_command = vim.env.LOCPATH, vim.cmd
local isolated = vim.fn.tempname()
vim.fn.mkdir(isolated, 'p')
vim.env.LOCPATH = isolated
local function start()
  zh.setup()
  assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end, 10))
  assert(native.info().active, vim.inspect(native.info()))
end
local passed, failure = xpcall(function()
  start()
  local attempts = {}
  vim.cmd = function(command)
    attempts[#attempts + 1] = { path = vim.env.LOCPATH }
    if #attempts == 1 then error('injected original LOCPATH restore failure') end
    return original_command(command)
  end
  assert(native.stop())
  vim.cmd = original_command
  assert(#attempts == 2 and attempts[1].path == isolated and attempts[2].path == nil,
    'restore must try original LOCPATH then temporarily clear it')
  assert(vim.env.LOCPATH == isolated and vim.v.lang == original_lang)
  assert(binding() == original_binding)
  start()
  attempts = {}
  vim.cmd = function(command)
    attempts[#attempts + 1] = { path = vim.env.LOCPATH }
    error('injected restore unavailable')
  end
  zh.setup({ modules = { core = { apply_language = false } } })
  -- The coordinator must preserve the backend failure rather than claim opt-out succeeded.
  assert(zh.status().runtime.status == 'error', vim.inspect(zh.status().runtime))
  assert(native.info().status == 'restore_failed' and native.info().active,
    'restore failure discarded retryable ownership')
  assert(#attempts == 2 and attempts[1].path == isolated and attempts[2].path == nil)
  assert(vim.env.LOCPATH == isolated, 'failed restore leaked temporary environment')
  vim.cmd = original_command
  assert(zh.teardown(), 'retry after restore failure failed')
  assert(native.info().status == 'disabled' and vim.v.lang == original_lang)
  assert(binding() == original_binding)
end, debug.traceback)
vim.cmd = original_command
pcall(zh.teardown)
vim.env.LOCPATH = original_path
vim.fn.delete(isolated, 'rf')
if not passed then error(failure, 0) end
print('NATIVE_RESTORE_SPEC=PASS original_path system_fallback restore_failed retry coordinator_error')
