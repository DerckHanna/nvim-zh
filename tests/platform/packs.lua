-- Platform probe for SDK 1 pack handling: import, digest rejection, damaged
-- snapshot fallback and registration atomicity. It runs on a real filesystem
-- of the host platform with an isolated Neovim user directory:
--   NVIM_ZH_ROOT=<checkout> [NVIM_ZH_PLATFORM_ASSETS=<dir with published clangd-0.1.N.json>]
--   nvim --headless -u NONE -i NONE -n -l tests/platform/packs.lua
-- The published historical attachments are verified against the digests of the
-- official catalog; without the directory only the synthetic section runs.
local root = assert(vim.env.NVIM_ZH_ROOT, 'set NVIM_ZH_ROOT to the checkout')
vim.opt.runtimepath:prepend(root)
local uv = vim.uv

local published = {
  ['0.1.0'] = 'cfd5cc74f9d3f6c5dd43a6b786abd9cb19c0ee02264f742523aa299ff9c3e385',
  ['0.1.1'] = 'a353e9f31e9975230f473106ca93043d1bf753e19bbcba9c78f5b604fc518dcb',
  ['0.1.2'] = '0dd6344f8921bcd37fb8daef01e0b7388206cc345f8585c349f8767eb75ae3ba',
}

local options = { modules = { core = { enabled = false }, plugins = { auto = false }, ui = { notify = false, prompts = false } } }
local zh = require('nvim-zh')
local fs = require('nvim-zh.fs')
local store = require('nvim-zh.pack_store')
local packs = require('nvim-zh.packs')
local notices = {}
vim.notify = function(message) notices[#notices + 1] = tostring(message) end

local function settle()
  assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end, 20),
    'runtime did not settle: ' .. vim.inspect(zh.status().runtime))
  local status = zh.status().runtime.status
  assert(status == 'ok' or status == 'degraded', vim.inspect(zh.status().runtime))
end

-- A restart replaces the in-memory session; the registration and snapshots on
-- disk are all that survive.
local function restart()
  assert(zh.teardown())
  zh.setup(options)
  settle()
end

zh.setup(options)
settle()

local scratch = vim.fn.tempname()
fs.mkdir(scratch)
local function write_pack(name, version, msgstr, extra)
  local catalog = vim.json.encode({ schema = 1, locale = 'zh_CN', domain = 'platform_demo',
    entries = { { context = '', msgid = 'Open', msgstr = msgstr } } })
  local files = { ['catalogs/zh_CN.json'] = catalog }
  local manifest = vim.tbl_extend('force', { schema = 1, sdk = 1, locale = 'zh_CN', id = 'platform-demo',
    domain = 'platform_demo', version = version, files = {} }, extra or {})
  for path, body in pairs(files) do manifest.files[path] = { sha256 = vim.fn.sha256(body), size = #body } end
  local path = scratch .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({ manifest = manifest, files = files }))
  return path
end
local function translate() return zh.translate({ domain = 'platform_demo', msgid = 'Open' }) end
local function state() return zh.status().packs['platform-demo'] or {} end
local function entries(folder)
  local names = {}
  for name in vim.fs.dir(folder) do names[#names + 1] = name end
  return names
end
local function damage(path)
  local bytes = fs.read(path, store.limit)
  local middle = math.floor(#bytes / 2)
  local replacement = bytes:sub(middle, middle) == 'x' and 'y' or 'x'
  local fd = assert(uv.fs_open(path, 'w', 438))
  assert(uv.fs_write(fd, bytes:sub(1, middle - 1) .. replacement .. bytes:sub(middle + 1), 0))
  uv.fs_close(fd)
end

-- 1. SDK 1 import and digest rejection.
local first = write_pack('one', '1.0.0', '打开')
local digest = packs.inspect(first).sha256
assert(not pcall(packs.import, first, false, string.rep('a', 64)), 'digest mismatch was accepted')
assert(not store.record('platform-demo').selected and translate() == 'Open', 'rejected import changed state')
assert(packs.import(first, false, digest) == 'platform-demo')
assert(translate() == '打开' and state().active == '1.0.0')
local second = write_pack('two', '1.1.0', '开启')
assert(packs.import(second, false) == 'platform-demo')
assert(state().selected == '1.1.0' and state().previous == '1.0.0' and translate() == '开启', vim.inspect(state()))
local stage_bytes = fs.read(second, store.limit)
assert(not pcall(store.stage, stage_bytes, { sha256 = string.rep('b', 64), size = #stage_bytes }),
  'index digest mismatch was staged')
assert(not pcall(store.stage, stage_bytes, { sha256 = vim.fn.sha256(stage_bytes), size = #stage_bytes + 1 }),
  'index size mismatch was staged')
assert(state().active == '1.1.0' and translate() == '开启', 'staging failure changed the active resource')

-- 2. Registration atomicity on this filesystem. The generation is published by
-- a hard link, so link creation and EEXIST must behave on the host.
local record = store.record('platform-demo')
local folder = store.root() .. '/state/platform-demo'
local probe_a, probe_b = folder .. '/atomic-a.tmp', folder .. '/atomic-b.tmp'
fs.write(probe_a, 'a')
local linked, why, code = uv.fs_link(probe_a, probe_b)
assert(linked, 'hard links are not available: ' .. tostring(why))
local again, _, repeat_code = uv.fs_link(probe_a, probe_b)
assert(not again and repeat_code == 'EEXIST', 'second link did not report EEXIST: ' .. tostring(repeat_code))
uv.fs_unlink(probe_a); uv.fs_unlink(probe_b)
assert(not pcall(store.commit, 'platform-demo', record.generation - 1, vim.deepcopy(record)),
  'stale generation replaced the current record')
assert(store.record('platform-demo').generation == record.generation)

local original_link = uv.fs_link
local third = write_pack('three', '1.2.0', '再开')
local function unsupported_link() return nil, 'EPERM: operation not permitted', 'EPERM' end
uv.fs_link = unsupported_link
local imported, failure = pcall(packs.import, third, false)
uv.fs_link = original_link
assert(not imported and tostring(failure):find('EPERM', 1, true), 'missing link support was not reported: ' .. tostring(failure))
local after = store.record('platform-demo')
assert(after.generation == record.generation and after.selected.version == '1.1.0', 'registration changed after failure')
assert(state().active == '1.1.0' and translate() == '开启', 'failed registration changed the active resource')
for _, name in ipairs(entries(folder)) do
  assert(not name:find('pending', 1, true) and not name:find('.tmp', 1, true), 'registration left a pending file: ' .. name)
end
assert(packs.import(third, false) == 'platform-demo' and state().active == '1.2.0' and translate() == '再开')
packs.change('platform-demo', 'rollback')
assert(state().active == '1.1.0' and translate() == '开启', vim.inspect(state()))

-- 3. Damaged snapshots fall back to the previous verified one. Recreate a
-- 1.0.0 -> 1.1.0 history with 1.2.0 removed from the picture.
packs.change('platform-demo', 'remove')
assert(packs.import(first, false) == 'platform-demo' and packs.import(second, false) == 'platform-demo')
local selected = store.record('platform-demo').selected
local previous = store.record('platform-demo').previous
damage(store.folder(selected) .. '/artifact.json')
restart()
assert(state().selected == '1.1.0' and state().active == '1.0.0' and state().error and translate() == '打开', vim.inspect(state()))
-- Importing the same attachment again repairs the damaged snapshot in place.
local damaged_folder = store.folder(selected)
assert(packs.import(second, false) == 'platform-demo')
assert(state().selected == '1.1.0' and state().active == '1.1.0' and not state().error and translate() == '开启', vim.inspect(state()))
assert(store.folder(store.record('platform-demo').selected) == damaged_folder)
for _, name in ipairs(entries(store.root() .. '/snapshots')) do
  assert(not name:find('damaged', 1, true) and not name:find('stage', 1, true), 'repair left a temporary folder: ' .. name)
end
damage(damaged_folder .. '/artifact.json')
restart()
assert(state().active == '1.0.0' and state().error and translate() == '打开', vim.inspect(state()))
packs.change('platform-demo', 'rollback')
assert(state().selected == '1.0.0' and state().active == '1.0.0' and not state().error and translate() == '打开', vim.inspect(state()))
-- A damaged member file is rejected by the same verification.
assert(packs.import(second, false) == 'platform-demo')
damage(store.folder(store.record('platform-demo').selected) .. '/catalogs/zh_CN.json')
restart()
assert(state().active == '1.0.0' and state().error and translate() == '打开', vim.inspect(state()))
-- Without a verified snapshot the display falls back to the source text and the registration survives.
damage(store.folder(previous) .. '/artifact.json')
restart()
assert(not state().active and translate() == 'Open' and store.record('platform-demo').selected, vim.inspect(state()))
packs.change('platform-demo', 'remove')
assert(not store.record('platform-demo').selected and translate() == 'Open')

-- 3b. SDK 2 single-file snapshot, damage fallback to SDK 1, in-place repair,
-- and offline rollback across SDK 2 <-> SDK 1 on this filesystem.
local function write_pack_sdk2(name, version, msgstr)
  local path = scratch .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({
    manifest = { schema = 1, sdk = 2, locale = 'zh_CN', id = 'platform-demo',
      domain = 'platform_demo', version = version, files = {} },
    catalog = { schema = 2, locale = 'zh_CN', domain = 'platform_demo',
      entries = { [''] = { Open = msgstr } } },
    files = {},
  }))
  return path
end
assert(packs.import(first, false) == 'platform-demo')
local sdk2_pack = write_pack_sdk2('sdk2', '2.0.0', '二代打开')
assert(packs.import(sdk2_pack, false, packs.inspect(sdk2_pack).sha256) == 'platform-demo')
assert(state().selected == '2.0.0' and state().active == '2.0.0' and state().previous == '1.0.0' and translate() == '二代打开',
  vim.inspect(state()))
local sdk2_folder = store.folder(store.record('platform-demo').selected)
assert(uv.fs_stat(sdk2_folder .. '/artifact.json') and not uv.fs_stat(sdk2_folder .. '/catalogs'),
  'SDK 2 snapshot should not extract catalogs/')
damage(sdk2_folder .. '/artifact.json')
restart()
assert(state().selected == '2.0.0' and state().active == '1.0.0' and state().error and translate() == '打开',
  vim.inspect(state()))
assert(packs.import(sdk2_pack, false) == 'platform-demo')
assert(state().selected == '2.0.0' and state().active == '2.0.0' and not state().error and translate() == '二代打开',
  vim.inspect(state()))
packs.change('platform-demo', 'rollback')
assert(state().selected == '1.0.0' and state().active == '1.0.0' and translate() == '打开', vim.inspect(state()))
packs.change('platform-demo', 'remove')
assert(not store.record('platform-demo').selected and translate() == 'Open')

-- 4. Published historical and formal attachments.
local summary = 'synthetic'
local assets = vim.env.NVIM_ZH_PLATFORM_ASSETS
if assets and assets ~= '' then
  local function attachment(version)
    local path = assets .. '/clangd-' .. version .. '.json'
    local bytes = fs.read(path, store.limit)
    assert(vim.fn.sha256(bytes) == published[version], 'published attachment digest differs: ' .. version)
    return path, vim.json.decode(bytes)
  end
  local function sample(doc)
    for _, row in ipairs(vim.json.decode(doc.files['catalogs/zh_CN.json']).entries) do
      if row.msgid:match('^[%w ]+$') and row.msgstr ~= row.msgid then return row end
    end
  end
  local function clangd() return zh.status().packs.clangd or {} end
  local old_path, old_doc = attachment('0.1.0')
  local mid_path, mid_doc = attachment('0.1.1')
  local current_path = attachment('0.1.2')
  local function shown(doc)
    local row = sample(doc)
    return zh.translate({ domain = 'clangd', context = row.context, msgid = row.msgid }), row.msgstr
  end
  assert(packs.import(old_path, false, published['0.1.0']) == 'clangd')
  assert(clangd().active == '0.1.0', vim.inspect(clangd()))
  assert(packs.import(mid_path, false, published['0.1.1']) == 'clangd')
  assert(clangd().active == '0.1.1' and clangd().previous == '0.1.0', vim.inspect(clangd()))
  local actual, expected = shown(mid_doc)
  assert(actual == expected, 'historical 0.1.1 text differs on this platform')
  damage(store.folder(store.record('clangd').selected) .. '/artifact.json')
  restart()
  assert(clangd().selected == '0.1.1' and clangd().active == '0.1.0' and clangd().error, vim.inspect(clangd()))
  actual, expected = shown(old_doc)
  assert(actual == expected, 'fallback 0.1.0 text differs on this platform')
  packs.change('clangd', 'rollback')
  assert(clangd().selected == '0.1.0' and clangd().active == '0.1.0' and not clangd().error, vim.inspect(clangd()))
  assert(packs.import(current_path, false, published['0.1.2']) == 'clangd')
  packs.prepare_domain('clangd')
  assert(vim.wait(20000, function() return clangd().active == '0.1.2' end, 20), vim.inspect(clangd()))
  packs.change('clangd', 'remove')
  summary = 'synthetic+published(0.1.0,0.1.1,0.1.2)'
end

assert(zh.teardown())
print(('PLATFORM_PACKS=PASS system=%s arch=%s nvim=%s sdk1=%s sdk2=synthetic import=digest_checked damaged=previous_verified atomic=link,eexist,stale,unsupported_reported')
  :format(uv.os_uname().sysname, uv.os_uname().machine, tostring(vim.version()), summary))
