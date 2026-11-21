-- Deferred preparation for large tool packs (>= 256 KiB) and compiler list
-- lifecycle: English fallback while preparing, cancellation, generation
-- change, synchronous translate(), damaged fallback, and compiler disable.
local zh = require('nvim-zh')
local fs = require('nvim-zh.fs')
local store = require('nvim-zh.pack_store')
local packs = require('nvim-zh.packs')
local uv = vim.uv

local function settle()
  assert(vim.wait(10000, function() return zh.status().runtime.status ~= 'syncing' end, 10),
    'runtime did not settle')
end

local opts = { modules = { core = { enabled = false }, plugins = { auto = false }, ui = { notify = false, prompts = false } } }
zh.setup(opts)
settle()

local tmp = assert(vim.env.NVIM_ZH_TMP)
local function write_large_clangd(name, version, msgstr, padding_count)
  local entries = {
    { context = 'diagnostic', msgid = "Redefinition of 'x'", msgstr = msgstr },
  }
  for i = 1, padding_count or 3500 do
    entries[#entries + 1] = {
      context = 'diagnostic',
      msgid = ('Synthetic deferred entry number %05d with padding text'):format(i),
      msgstr = ('合成延迟词条编号 %05d 用于测试分片准备'):format(i),
    }
  end
  local catalog_json = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = 'clangd', entries = entries })
  local files = { ['catalogs/zh_CN.json'] = catalog_json }
  local manifest = {
    schema = 1, sdk = 1, locale = 'zh_CN', id = 'clangd', domain = 'clangd', version = version,
    executable = 'clangd',
    files = { ['catalogs/zh_CN.json'] = { sha256 = vim.fn.sha256(catalog_json), size = #catalog_json } },
  }
  local path = tmp .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({ manifest = manifest, files = files }))
  assert(uv.fs_stat(path).size >= 256 * 1024, 'fixture must exceed 256 KiB defer threshold')
  return path
end

local function write_small_clangd(name, version, msgstr)
  local catalog_json = vim.json.encode({
    schema = 1, locale = 'zh_CN', domain = 'clangd',
    entries = { { context = 'diagnostic', msgid = "Redefinition of 'x'", msgstr = msgstr } },
  })
  local files = { ['catalogs/zh_CN.json'] = catalog_json }
  local manifest = {
    schema = 1, sdk = 1, locale = 'zh_CN', id = 'clangd', domain = 'clangd', version = version,
    executable = 'clangd',
    files = { ['catalogs/zh_CN.json'] = { sha256 = vim.fn.sha256(catalog_json), size = #catalog_json } },
  }
  local path = tmp .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({ manifest = manifest, files = files }))
  return path
end

local small_v1 = write_small_clangd('clangd-v1', '0.1.0', "旧版 'x' 重复定义")
local large_v2 = write_large_clangd('clangd-v2', '0.1.2', "新版 'x' 重复定义")
local large_v3 = write_large_clangd('clangd-v3', '0.1.3', "三版 'x' 重复定义")

-- Seed 0.1.0 -> 0.1.2, then restart to enter deferred startup state.
assert(packs.import(small_v1, false) == 'clangd')
assert(packs.import(large_v2, false) == 'clangd')
assert(zh.teardown())
zh.setup(opts)
settle()

-- 1. Startup defers large tool pack without loading its catalog.
local state = zh.status().packs.clangd
assert(state and state.pending == true and state.selected == '0.1.2' and not state.active, vim.inspect(state))
assert(packs.tool_reason('clangd') == 'preparing_pack', packs.tool_reason('clangd'))
assert(require('nvim-zh.catalog').revision('clangd') >= 0)

-- 2. Async preparation falls back to English while in progress, then applies.
local done = false
assert(packs.ensure_tool('clangd', true, function() done = true end) == false, 'first async call should defer')
assert(packs.tool_allows('clangd') == false, 'tool_allows must return false while preparing')
local vt = vim.diagnostic.config().virtual_text and vim.diagnostic.config().virtual_text.format
if vt then
  local sample = { source = 'clangd', code = 'redefinition', message = "Redefinition of 'x'" }
  assert(vt(sample) == "Redefinition of 'x'", 'diagnostic did not fall back to English while preparing')
end
assert(vim.wait(10000, function() return done and zh.status().packs.clangd.active == '0.1.2' end, 10),
  'async preparation did not complete: ' .. vim.inspect(zh.status().packs.clangd))
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "新版 'x' 重复定义")

-- 3. Cancellation mid-preparation (teardown) aborts cleanly and stays English.
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.status().packs.clangd.pending == true)
local cancelled_done = false
assert(packs.ensure_tool('clangd', true, function() cancelled_done = true end) == false)
assert(zh.teardown())
vim.wait(100, function() return false end, 10)
assert(not cancelled_done, 'cancelled preparation invoked callback after teardown')
assert(not zh.status().packs.clangd, 'cancelled preparation mounted pack after teardown')
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "Redefinition of 'x'")

-- 4. Disable mid-preparation cancels deferred worker and falls back to English.
zh.setup(opts)
settle()
local disable_done = false
assert(packs.ensure_tool('clangd', true, function() disable_done = true end) == false)
packs.change('clangd', 'disable')
vim.wait(100, function() return false end, 10)
assert(not disable_done, 'disabled pack invoked stale preparation callback')
assert(zh.status().packs.clangd.enabled == false and not zh.status().packs.clangd.active)
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "Redefinition of 'x'")
packs.change('clangd', 'enable')

-- 5. Generation change mid-preparation (new version imported) invalidates old worker.
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.status().packs.clangd.pending == true)
local stale_done = false
assert(packs.ensure_tool('clangd', true, function() stale_done = true end) == false)
assert(packs.import(large_v3, false) == 'clangd')
vim.wait(100, function() return false end, 10)
assert(not stale_done, 'stale worker callback ran after generation change')
assert(zh.status().packs.clangd.active == '0.1.3', vim.inspect(zh.status().packs.clangd))
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "三版 'x' 重复定义")

-- 6. Synchronous translate() while deferred (and mid-preparing) completes without network.
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.status().packs.clangd.pending == true)
local system = vim.system
vim.system = function(argv, ...) assert(argv[1] ~= 'curl', 'translate used network'); return system(argv, ...) end
assert(packs.ensure_tool('clangd', true) == false)
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "三版 'x' 重复定义")
assert(zh.status().packs.clangd.active == '0.1.3')
vim.system = system

-- 7. Damaged deferred snapshot falls back to verified previous snapshot on first use.
packs.change('clangd', 'remove')
assert(packs.import(small_v1, false) == 'clangd')
assert(packs.import(large_v2, false) == 'clangd')
local selected = store.record('clangd').selected
fs.write(store.folder(selected) .. '/artifact.json', string.rep('x', 300 * 1024))
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.status().packs.clangd.pending == true)
assert(zh.translate({ domain = 'clangd', context = 'diagnostic', msgid = "Redefinition of 'x'" }) == "旧版 'x' 重复定义")
assert(zh.status().packs.clangd.active == '0.1.0' and zh.status().packs.clangd.error, vim.inspect(zh.status().packs.clangd))

-- 8. Disabling compiler module via setup() releases our autocmd group and formatters.
local foreign = function() return { 'foreign' } end
vim.fn.setqflist({}, ' ', { title = 'foreign', quickfixtextfunc = foreign })
local foreign_id = vim.fn.getqflist({ id = 0 }).id
assert(#vim.api.nvim_get_autocmds({ group = 'NvimZhCompiler' }) >= 1)
zh.setup(vim.tbl_deep_extend('force', opts, { modules = { compiler = { enabled = false } } }))
settle()
assert(not pcall(vim.api.nvim_get_autocmds, { group = 'NvimZhCompiler' }), 'compiler autocmd survived disable')
assert(rawequal(vim.fn.getqflist({ id = foreign_id, quickfixtextfunc = 1 }).quickfixtextfunc, foreign),
  'compiler disable removed foreign formatter')

assert(zh.teardown())
print('PACK_DEFERRED_SPEC=PASS defer async_fallback teardown_cancel disable_cancel generation_change sync_translate damaged_fallback compiler_disable')
