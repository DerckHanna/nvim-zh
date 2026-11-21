-- SDK 2 single-layer compact attachment lifecycle, cross-SDK rollback,
-- invalid-payload rejection, deferred loading, and mixed-SDK catalog selection.
local zh = require('nvim-zh')
local fs = require('nvim-zh.fs')
local store = require('nvim-zh.pack_store')
local packs = require('nvim-zh.packs')
local catalog = require('nvim-zh.catalog')
local uv = vim.uv

local function settle()
  assert(vim.wait(10000, function() return zh.status().runtime.status ~= 'syncing' end, 10),
    'runtime did not settle')
end

local opts = { modules = { core = { enabled = false }, plugins = { auto = false }, ui = { notify = false, prompts = false } } }
zh.setup(opts)
settle()

local tmp = assert(vim.env.NVIM_ZH_TMP)
local known_clangd = 'clangd version 23.1.5 linux x86_64-pc-linux-gnu'

local function write_sdk1(name, id, version, entries, extra)
  local cat_json = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = id, entries = entries })
  local files = { ['catalogs/zh_CN.json'] = cat_json }
  local manifest = vim.tbl_extend('force', {
    schema = 1, sdk = 1, locale = 'zh_CN', id = id, domain = id, version = version,
    files = { ['catalogs/zh_CN.json'] = { sha256 = vim.fn.sha256(cat_json), size = #cat_json } },
  }, extra or {})
  local path = tmp .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({ manifest = manifest, files = files }))
  return path
end

local function write_sdk2(name, id, version, entries_map, extra)
  local manifest = vim.tbl_extend('force', {
    schema = 1, sdk = 2, locale = 'zh_CN', id = id, domain = id, version = version, files = {},
  }, extra or {})
  local doc = {
    manifest = manifest,
    catalog = { schema = 2, locale = 'zh_CN', domain = id, entries = entries_map },
    files = {},
  }
  local path = tmp .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode(doc))
  return path
end

-- 1. SDK 2 import, single-file snapshot (no extracted catalogs/zh_CN.json),
--    exact + template + %% unescape + non-mutating override overlay.
local sdk1_path = write_sdk1('clang-v1', 'clang', '0.1.0', {
  { context = 'diagnostic', msgid = "use of undeclared identifier '%0'", msgstr = "SDK1 未声明的标识符 '%0'" },
  { context = 'diagnostic', msgid = '100%% literal', msgstr = 'SDK1 100%% 字面量' },
}, { executable = 'clang' })

local sdk2_entries = {
  diagnostic = {
    ["use of undeclared identifier '%0'"] = "SDK2 未声明的标识符 '%0'",
    ['100%% literal'] = 'SDK2 100%% 字面量',
    ['Exact item'] = 'SDK2 精确词条',
  },
}
for i = 1, 3600 do
  sdk2_entries.diagnostic[('Synthetic SDK2 deferred entry %05d with padding text'):format(i)] =
    ('合成 SDK2 延迟词条 %05d 用于分片加载验证'):format(i)
end
local sdk2_path = write_sdk2('clang-v2', 'clang', '0.2.0', sdk2_entries, { executable = 'clang' })
assert(uv.fs_stat(sdk2_path).size >= 256 * 1024, 'SDK 2 fixture must exceed 256 KiB defer threshold')

assert(packs.import(sdk1_path, false) == 'clang')
assert(zh.status().packs.clang.active == '0.1.0')
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'x'", formatted = true })
  == "SDK1 未声明的标识符 'x'")

local inspected = packs.inspect(sdk2_path)
assert(inspected.id == 'clang' and inspected.version == '0.2.0' and inspected.lua == false)
assert(packs.import(sdk2_path, false, inspected.sha256) == 'clang')
assert(zh.status().packs.clang.active == '0.2.0' and zh.status().packs.clang.previous == '0.1.0')

-- Verify snapshot contains only artifact.json (no redundant catalogs/zh_CN.json).
local sdk2_folder = store.folder(store.record('clang').selected)
assert(uv.fs_stat(sdk2_folder .. '/artifact.json') and not uv.fs_stat(sdk2_folder .. '/catalogs'),
  'SDK 2 pure-data tool pack should not extract redundant catalogs/ directory')

assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Exact item' }) == 'SDK2 精确词条')
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'foo'", formatted = true })
  == "SDK2 未声明的标识符 'foo'")
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = '100% literal' }) == 'SDK2 100% 字面量')
assert(catalog.is_translation('clang', 'diagnostic', 'SDK2 精确词条') == 'clang:diagnostic:Exact item')

-- Non-mutating overrides on mounted SDK 2 pack (base source already released).
zh.setup(vim.tbl_deep_extend('force', opts, {
  overrides = {
    clang = {
      diagnostic = {
        ['Exact item'] = '覆盖精确词条',
        ["use of undeclared identifier '%0'"] = "覆盖未声明标识符 '%0'",
        ['Custom %0 template'] = '自定义模板 %0',
      },
    },
  },
}))
settle()
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Exact item' }) == '覆盖精确词条')
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'bar'", formatted = true })
  == "覆盖未声明标识符 'bar'")
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Custom abc template', formatted = true })
  == '自定义模板 abc')
zh.setup(opts)
settle()
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Exact item' }) == 'SDK2 精确词条')
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'bar'", formatted = true })
  == "SDK2 未声明的标识符 'bar'")

-- 2. Deferred startup on large SDK 2 pack + async English fallback + completion.
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.status().packs.clang.pending == true and zh.status().packs.clang.selected == '0.2.0'
  and not zh.status().packs.clang.active, vim.inspect(zh.status().packs.clang))
local done = false
assert(packs.ensure_tool('clang', true, function() done = true end) == false)
assert(packs.tool_allows('clang') == false)
assert(vim.wait(10000, function() return done and zh.status().packs.clang.active == '0.2.0' end, 10))
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Exact item' }) == 'SDK2 精确词条')

-- 3. Damaged SDK 2 snapshot falls back to verified SDK 1 previous, re-import repairs in place,
--    and offline rollback switches SDK 2 -> SDK 1 without network.
local raw_sdk2 = fs.read(sdk2_folder .. '/artifact.json', store.limit)
local mid = math.floor(#raw_sdk2 / 2)
local flipped = raw_sdk2:sub(mid, mid) == 'x' and 'y' or 'x'
fs.write(sdk2_folder .. '/artifact.json', raw_sdk2:sub(1, mid - 1) .. flipped .. raw_sdk2:sub(mid + 1))
assert(zh.teardown())
zh.setup(opts)
settle()
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'z'", formatted = true })
  == "SDK1 未声明的标识符 'z'")
assert(zh.status().packs.clang.selected == '0.2.0' and zh.status().packs.clang.active == '0.1.0'
  and zh.status().packs.clang.error, vim.inspect(zh.status().packs.clang))

local before_gen = store.record('clang').generation
assert(packs.import(sdk2_path, false) == 'clang')
assert(store.record('clang').generation == before_gen)
assert(zh.status().packs.clang.active == '0.2.0' and not zh.status().packs.clang.error)
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = 'Exact item' }) == 'SDK2 精确词条')

local orig_system = vim.system
vim.system = function(argv, ...) assert(argv[1] ~= 'curl', 'offline rollback used network'); return orig_system(argv, ...) end
packs.change('clang', 'rollback')
vim.system = orig_system
assert(zh.status().packs.clang.selected == '0.1.0' and zh.status().packs.clang.active == '0.1.0')
assert(zh.translate({ domain = 'clang', context = 'diagnostic', msgid = "use of undeclared identifier 'q'", formatted = true })
  == "SDK1 未声明的标识符 'q'")

-- 4. Invalid SDK 2 & cross-SDK payload rejections.
local bad_utf8 = tmp .. '/bad-utf8.json'
fs.write(bad_utf8, vim.json.encode({
  manifest = { schema = 1, sdk = 2, locale = 'zh_CN', id = 'bad-u', domain = 'bad-u', version = '0.2.0', files = {} },
  catalog = { schema = 2, locale = 'zh_CN', domain = 'bad-u', entries = { [''] = { a = 'b' } } },
  files = {},
}):gsub('"b"', '"\255"'))
assert(not pcall(packs.import, bad_utf8, false), 'SDK 2 invalid UTF-8 was accepted')

local bad_dual = tmp .. '/bad-dual.json'
local inner = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = 'bad-d', entries = {} })
fs.write(bad_dual, vim.json.encode({
  manifest = { schema = 1, sdk = 2, locale = 'zh_CN', id = 'bad-d', domain = 'bad-d', version = '0.2.0',
    files = { ['catalogs/zh_CN.json'] = { sha256 = vim.fn.sha256(inner), size = #inner } } },
  catalog = { schema = 2, locale = 'zh_CN', domain = 'bad-d', entries = {} },
  files = { ['catalogs/zh_CN.json'] = inner },
}))
assert(not pcall(packs.import, bad_dual, false), 'SDK 2 with files[catalogs/zh_CN.json] was accepted')

local bad_empty = tmp .. '/bad-empty.json'
fs.write(bad_empty, vim.json.encode({
  manifest = { schema = 1, sdk = 2, locale = 'zh_CN', id = 'bad-e', domain = 'bad-e', version = '0.2.0', files = {} },
  files = {},
}))
assert(not pcall(packs.import, bad_empty, false), 'empty SDK 2 pack was accepted')

local bad_sdk1_top = tmp .. '/bad-sdk1-top.json'
fs.write(bad_sdk1_top, vim.json.encode({
  manifest = { schema = 1, sdk = 1, locale = 'zh_CN', id = 'bad-1', domain = 'bad-1', version = '0.1.0',
    files = { ['catalogs/zh_CN.json'] = { sha256 = vim.fn.sha256(inner), size = #inner } } },
  catalog = { schema = 2, locale = 'zh_CN', domain = 'bad-1', entries = {} },
  files = { ['catalogs/zh_CN.json'] = inner },
}))
assert(not pcall(packs.import, bad_sdk1_top, false), 'SDK 1 with top-level catalog was accepted')

-- 5. Mixed catalog.json (SDK 1 0.1.0/0.1.2 + SDK 2 0.2.0) selection & dedup.
local origin = 'https://raw.githubusercontent.com/DerckHanna/nvim-zh/packs/catalog.json'
local release = 'https://github.com/DerckHanna/nvim-zh/releases/download/'
local tool = { protocol = 'lsp', server = 'clangd', versions = { [known_clangd] = { 'textDocument/publishDiagnostics' } } }
local mixed = {
  schema = 1,
  packages = {
    { id = 'clangd', version = '0.1.0', executable = 'clangd', locale = 'zh_CN', sdk = 1,
      url = release .. 'packs-clangd-v0.1.0/clangd-zh_CN.json', sha256 = string.rep('0', 64), size = 128 },
    { id = 'clangd', version = '0.1.2', executable = 'clangd', locale = 'zh_CN', sdk = 1,
      url = release .. 'packs-clangd-v0.1.2/clangd-zh_CN.json', sha256 = string.rep('2', 64), size = 256, tool = tool },
    { id = 'clangd', version = '0.2.0', executable = 'clangd', locale = 'zh_CN', sdk = 2,
      url = release .. 'packs-clangd-v0.2.0/clangd-zh_CN.json', sha256 = string.rep('4', 64), size = 192, tool = tool },
  },
}
fs.write(store.root() .. '/catalogs/official.json', vim.json.encode({
  origin = origin, checked_at = os.time(), body = vim.json.encode(mixed),
}))
packs.configure({})
local get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
  return { { id = 7, initialized = true, server_info = { name = 'clangd', version = known_clangd } } }
end
local clangd_row = assert(vim.iter(packs.rows()):find(function(item) return item.id == 'clangd' end))
vim.lsp.get_clients = get_clients
assert(clangd_row.update and clangd_row.update.version == '0.2.0' and clangd_row.update.sdk == 2, vim.inspect(clangd_row))
assert(#clangd_row.options == 3 and clangd_row.options[2].version == '0.1.2' and clangd_row.options[2].sdk == 1)

-- Duplicate (id, version, locale) across SDK 1 & SDK 2 in catalog.json must be rejected.
local dup_catalog = {
  schema = 1,
  packages = {
    mixed.packages[2],
    vim.tbl_extend('force', {}, mixed.packages[2], { sdk = 2, sha256 = string.rep('5', 64) }),
  },
}
fs.write(store.root() .. '/catalogs/official.json', vim.json.encode({
  origin = origin, checked_at = os.time(), body = vim.json.encode(dup_catalog),
}))
packs.configure({ dummy = { url = 'https://example.invalid/empty.json', allow_lua = false } })
assert(not vim.iter(packs.rows()):any(function(item) return item.id == 'clangd' end),
  'duplicate (id, version, locale) catalog was accepted')

packs.change('clang', 'remove')
assert(zh.teardown())
print('PACK_SDK2_SPEC=PASS import single_file_snapshot overrides deferred damage_fallback_sdk1 offline_rollback invalid_reject mixed_catalog dedup')
