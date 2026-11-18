local zh = require('nvim-zh')
local paths = require('nvim-zh.paths')
local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Linux' then print('NATIVE_AUTO_SPEC=SKIP unsupported platform'); return end
local before, keys = {}, { 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LOCPATH' }
for _, key in ipairs(keys) do before[key] = vim.env[key] end
local lang, ctype, time, helplang = vim.v.lang, vim.v.ctype, vim.v.lc_time, vim.o.helplang
local isolate = vim.fn.tempname()
vim.fn.mkdir(isolate, 'p')
local private = vim.fn.executable('localedef') == 1 and vim.fn.filereadable('/usr/share/i18n/locales/zh_CN') == 1
if private then vim.env.LOCPATH = isolate end
vim.env.LANGUAGE = nil
local expected = {}
for _, key in ipairs(keys) do expected[key] = vim.env[key] end
zh.setup()
assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end, 20), 'locale generation timed out')
local native = zh.status().native
if native.status == 'unsupported' then print('NATIVE_AUTO_SPEC=SKIP ' .. native.reason); return end
if not native.active and not private then
  print('NATIVE_AUTO_SPEC=SKIP locale capability unavailable: ' .. tostring(native.reason)); return
end
assert(native.active and native.status == 'ok', vim.inspect(native))
if private then assert(native.private_locale, 'empty LOCPATH did not trigger private locale preparation') end
local active = require('nvim-zh.resources').active()
local probe = active.summary.native.probe
assert(vim.fn.gettext(probe.msgid) == probe.msgstr, 'actual gettext lookup failed')
for _, key in ipairs(keys) do assert(vim.env[key] == expected[key], key .. ' leaked into child environment') end
assert(vim.v.ctype == ctype and vim.v.lc_time == time, 'other locale categories changed')
local child = vim.system({ 'sh', '-c', 'printf "%s" "$LC_ALL"' }):wait()
assert(child.stdout == (expected.LC_ALL or ''), 'child environment changed')
zh.setup({ modules = { core = { apply_language = false } } })
assert(vim.v.lang == lang, 'explicit opt-out did not restore original message language')
assert(not zh.status().native.active)
for _, key in ipairs(keys) do vim.env[key] = before[key] end
vim.o.helplang = helplang
vim.fn.delete(isolate, 'rf')
print('NATIVE_AUTO_SPEC=PASS real_gettext env_preserved child_env_preserved categories_preserved opt_out_restore private_locale=' .. tostring(private))
