local zh = require('nvim-zh')
local packs = require('nvim-zh.packs')
local store = require('nvim-zh.pack_store')
local fs = require('nvim-zh.fs')
zh.setup({ modules = { core = { enabled = false } } })
assert(not next(zh.status().packs) and not next(zh.status().adapters))

local function write(name, files, meta)
  local manifest = vim.tbl_extend('force', { schema = 1, sdk = 1, locale = 'zh_CN',
    id = 'demo', domain = 'demo', version = '1.0.0', files = {} }, meta or {})
  for path, body in pairs(files) do manifest.files[path] = { sha256 = vim.fn.sha256(body), size = #body } end
  local path = vim.env.NVIM_ZH_TMP .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({ manifest = manifest, files = files }))
  return path
end

local catalog = { ['catalogs/zh_CN.json'] = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = 'demo',
  entries = { { context = '', msgid = 'Open', msgstr = '打开' } } }) }
local local_pack = write('data', catalog)
local digest = packs.inspect(local_pack).sha256
assert(not pcall(packs.import, local_pack, false, string.rep('a', 64)))
assert(packs.import(local_pack, false, digest) == 'demo')
assert(zh.translate({ domain = 'demo', msgid = 'Open' }) == '打开')

local first = store.record('demo')
packs.change('demo', 'disable', first.generation)
assert(not pcall(store.commit, 'demo', first.generation, first), 'stale write replaced the current generation')
assert(zh.translate({ domain = 'demo', msgid = 'Open' }) == 'Open')
packs.change('demo', 'enable')
assert(zh.translate({ domain = 'demo', msgid = 'Open' }) == '打开')

local executable = vim.tbl_extend('force', catalog, { ['adapter/entry.lua'] = 'error("unexpected loading")' })
local unsafe = write('lua', executable, { version = '1.1.0', adapter = { domain = 'demo',
  repository = 'https://example.invalid/demo', surfaces = {}, targets = {}, modules = {}, lazy_names = {} } })
assert(not pcall(packs.import, unsafe, false), 'unapproved Lua was imported')
assert(zh.status().packs.demo.active == '1.0.0')
packs.change('demo', 'remove')
local installed, why = pcall(packs.import, unsafe, true)
assert(not installed and tostring(why):find('unexpected loading', 1, true))
assert(not store.record('demo').selected and not zh.status().packs.demo, 'failed activation changed the registration')
assert(packs.import(local_pack, false) == 'demo', 'valid import could not recover after failed activation')
assert(not pcall(packs.import, write('path', { ['../invalid.lua'] = 'bad' }), true))
assert(zh.status().packs.demo.active == '1.0.0', 'failed update disturbed the active pack')

local original = store.record('demo').selected
local revised = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = 'demo',
  entries = { { context = '', msgid = 'Open', msgstr = '开启' } } })
assert(packs.import(write('same-version-new-content', { ['catalogs/zh_CN.json'] = revised }), false) == 'demo')
local state = zh.status().packs.demo
assert(state.selected == original.version and state.active == original.version and state.active_sha256 ~= original.sha256)
assert(zh.translate({ domain = 'demo', msgid = 'Open' }) == '开启')
packs.change('demo', 'rollback')
assert(zh.status().packs.demo.active_sha256 == original.sha256)
assert(zh.translate({ domain = 'demo', msgid = 'Open' }) == '打开')

-- Importing the selected attachment again repairs its damaged snapshot without a new registration.
local current = store.record('demo')
vim.fn.writefile({ 'damaged' }, store.folder(current.selected) .. '/artifact.json')
assert(not pcall(store.load, 'demo', current.selected), 'damaged snapshot passed verification')
assert(packs.import(local_pack, false) == 'demo')
assert(pcall(store.load, 'demo', current.selected) and store.record('demo').generation == current.generation,
  'repair rewrote the registration')
assert(zh.status().packs.demo.active_sha256 == current.selected.sha256 and zh.translate({ domain = 'demo', msgid = 'Open' }) == '打开')
assert(not vim.iter(vim.fs.dir(store.root() .. '/snapshots')):any(function(name) return name:find('damaged', 1, true) end))

packs.change('demo', 'remove')
assert(not zh.status().packs.demo and zh.translate({ domain = 'demo', msgid = 'Open' }) == 'Open')
assert(store.record('demo').generation > first.generation)
print('PACK_STORE_SPEC=PASS trust digest guard pause stale_generation activation_recovery snapshot_repair uninstall')
