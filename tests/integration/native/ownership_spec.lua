local zh = require('nvim-zh')
local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Linux' then print('NATIVE_OWNERSHIP_SPEC=SKIP unsupported platform'); return end
ffi.cdef[[char *bindtextdomain(const char *, const char *);]]
local function binding() return ffi.string(ffi.C.bindtextdomain('nvim', nil)) end
local original_binding, original_lang = binding(), vim.v.lang
zh.setup()
assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end, 20))
if not zh.status().native.active then print('NATIVE_OWNERSHIP_SPEC=SKIP native capability unavailable'); return end
local external = vim.fn.tempname()
ffi.C.bindtextdomain('nvim', external)
zh.teardown()
assert(binding() == external, 'teardown replaced external gettext binding')
assert(vim.v.lang == original_lang, 'still-owned message language was not restored')
ffi.C.bindtextdomain('nvim', original_binding)
zh.setup()
assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end, 20))
vim.cmd('language messages C')
local external_lang = vim.v.lang
zh.teardown()
assert(vim.v.lang == external_lang, 'teardown replaced external message language')
assert(binding() == original_binding, 'still-owned binding was not restored')
print('NATIVE_OWNERSHIP_SPEC=PASS independent_binding_and_language_ownership')
