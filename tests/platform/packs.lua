-- Run against the host filesystem with isolated XDG directories.
-- NVIM_ZH_ROOT=<checkout> nvim --headless -u NONE -i NONE -n -l tests/platform/packs.lua
local root = assert(vim.env.NVIM_ZH_ROOT, 'set NVIM_ZH_ROOT to the checkout')
vim.opt.runtimepath:prepend(root)
local uv = vim.uv

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
local member = 'help/platform.txt/doc/platform.cnx'
local function write_pack(name, version, msgstr)
  local help = '*nvim-zh-platform-fixture* ' .. msgstr
  local path = scratch .. '/' .. name .. '.json'
  fs.write(path, vim.json.encode({
    manifest = { schema = 1, sdk = 2, locale = 'zh_CN', id = 'platform-demo',
      domain = 'platform_demo', version = version,
      files = { [member] = { sha256 = vim.fn.sha256(help), size = #help } } },
    catalog = { schema = 2, locale = 'zh_CN', domain = 'platform_demo',
      entries = { [''] = { Open = msgstr } } },
    files = { [member] = help },
  }))
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

-- SDK 2 import and digest rejection.
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
assert(not uv.fs_stat(store.folder(selected) .. '/catalogs'), 'SDK 2 extracted its embedded catalog')
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
damage(store.folder(store.record('platform-demo').selected) .. '/' .. member)
restart()
assert(state().active == '1.0.0' and state().error and translate() == '打开', vim.inspect(state()))
-- Without a verified snapshot the display falls back to the source text and the registration survives.
damage(store.folder(previous) .. '/artifact.json')
restart()
assert(not state().active and translate() == 'Open' and store.record('platform-demo').selected, vim.inspect(state()))
packs.change('platform-demo', 'remove')
assert(not store.record('platform-demo').selected and translate() == 'Open')

assert(zh.teardown())
print(('PLATFORM_PACKS=PASS system=%s arch=%s nvim=%s sdk=2 import=digest_checked damaged=previous_verified atomic=link,eexist,stale,unsupported_reported')
  :format(uv.os_uname().sysname, uv.os_uname().machine, tostring(vim.version())))
