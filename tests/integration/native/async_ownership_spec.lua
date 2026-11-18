local zh = require('nvim-zh')
local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Linux' then print('ASYNC_NATIVE_OWNERSHIP_SPEC=SKIP unsupported platform'); return end
if vim.fn.executable('localedef') ~= 1 or vim.fn.filereadable('/usr/share/i18n/locales/zh_CN') ~= 1 then
  print('ASYNC_NATIVE_OWNERSHIP_SPEC=SKIP localedef capability unavailable')
  return
end
ffi.cdef[[char *bindtextdomain(const char *, const char *);]]
local original_binding = ffi.string(ffi.C.bindtextdomain('nvim', nil))
local original_lang = vim.v.lang
local original_helplang = vim.o.helplang
local vars = { 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LOCPATH' }
local original_env = {}
for _, name in ipairs(vars) do original_env[name] = vim.env[name] end
local isolate = vim.fn.tempname()
vim.fn.mkdir(isolate, 'p')
local external = vim.fn.tempname()
vim.fn.mkdir(external, 'p')
local original_system = vim.system
local pending
local passed, failure = xpcall(function()
  for _, code in ipairs({ 0, 1 }) do
  vim.fn.delete(require('nvim-zh.paths').data() .. '/native/locales', 'rf')
  vim.env.LOCPATH = isolate
  vim.env.LANGUAGE = nil
  vim.system = function(command, opts, callback)
    if command[1] ~= 'localedef' then return original_system(command, opts, callback) end
    pending = callback
    return { kill = function() end }
  end
  zh.setup()
  assert(pending, 'isolated LOCPATH did not enter asynchronous locale preparation')
  assert(zh.status().runtime.status == 'syncing')
  vim.cmd('language messages C')
  ffi.C.bindtextdomain('nvim', external)
  pending({ code = code, stderr = code == 0 and '' or 'injected localedef failure' })
  assert(vim.wait(5000, function() return zh.status().runtime.status ~= 'syncing' end, 20),
    'asynchronous native completion did not finish')
  assert(vim.v.lang == 'C', 'asynchronous completion overrode external language')
  assert(ffi.string(ffi.C.bindtextdomain('nvim', nil)) == external,
    'asynchronous completion overrode external gettext binding')
  assert(zh.status().native.status == 'degraded' and zh.status().native.reason == 'external_override',
    vim.inspect(zh.status().native))
    zh.teardown()
    ffi.C.bindtextdomain('nvim', original_binding)
    for _, name in ipairs(vars) do vim.env[name] = original_env[name] end
    vim.cmd('silent language messages ' .. vim.fn.fnameescape(original_lang))
  end
end, debug.traceback)
vim.system = original_system
pcall(zh.teardown)
ffi.C.bindtextdomain('nvim', original_binding)
for _, name in ipairs(vars) do vim.env[name] = original_env[name] end
pcall(vim.cmd, 'silent language messages ' .. vim.fn.fnameescape(original_lang))
vim.o.helplang = original_helplang
vim.fn.delete(isolate, 'rf')
vim.fn.delete(external, 'rf')
if not passed then error(failure, 0) end
print('ASYNC_NATIVE_OWNERSHIP_SPEC=PASS success_and_failure_external_binding_and_language_preserved')
