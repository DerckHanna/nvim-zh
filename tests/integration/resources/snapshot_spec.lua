local zh = require('nvim-zh')
local paths = require('nvim-zh.paths')
local fs = require('nvim-zh.fs')
local resources = require('nvim-zh.resources')
local uv = vim.uv or vim.loop
zh.setup({ modules = { core = { enabled = false } } })
local original_root, previous = paths.root, resources.active()
assert(previous, vim.inspect(zh.status().runtime))
local tmp = vim.fn.tempname()
fs.mkdir(tmp .. '/resources')
local manifest = fs.json(original_root .. '/resources/manifest.json')
for name in pairs(manifest.bundle.files) do fs.write(tmp .. '/resources/' .. name, fs.read(original_root .. '/resources/' .. name)) end
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(manifest))
paths.root = tmp
local function refresh()
  local result
  zh.refresh(function(value) result = value end)
  assert(vim.wait(5000, function() return result ~= nil end, 20), 'refresh timed out')
  return result
end
local function reject(message)
  local result = refresh()
  assert(not result.ok, message .. ' accepted')
  assert(resources.active().manifest.bundle.id == previous.manifest.bundle.id, message .. ' displaced old snapshot')
end
local name = 'catalogs/nvim-ui.json'
local bytes = fs.read(tmp .. '/resources/' .. name)
fs.write(tmp .. '/resources/' .. name, bytes .. 'bad')
reject('bad checksum')
fs.write(tmp .. '/resources/' .. name, bytes)
local invalid = vim.deepcopy(manifest)
invalid.bundle.files['help/doc/intro.cnx'] = nil
invalid.bundle.id = fs.index_id(invalid.bundle.files)
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(invalid))
reject('Help index with missing document')
local mo_name = 'native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
local mo = fs.read(tmp .. '/resources/' .. mo_name)
local bad_mo = mo:sub(1, 12) .. string.char(255, 255, 255, 255) .. mo:sub(17)
fs.write(tmp .. '/resources/' .. mo_name, bad_mo)
invalid = vim.deepcopy(manifest)
invalid.bundle.files[mo_name] = { size = #bad_mo, sha256 = vim.fn.sha256(bad_mo) }
invalid.bundle.id = fs.index_id(invalid.bundle.files)
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(invalid))
reject('MO index outside file bounds')
fs.write(tmp .. '/resources/' .. mo_name, mo)
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(manifest))
local future = vim.deepcopy(manifest)
future.runtime_api = 999
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(future))
reject('future schema')
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(manifest))
uv.fs_unlink(tmp .. '/resources/' .. name)
assert(uv.fs_symlink(original_root .. '/resources/' .. name, tmp .. '/resources/' .. name))
reject('symlink resource')
uv.fs_unlink(tmp .. '/resources/' .. name)
fs.write(tmp .. '/resources/' .. name, bytes)
local source = vim.json.decode(bytes)
for _, entry in ipairs(source.entries) do if entry.msgid == 'No information available' then entry.msgstr = '新资源已生效' end end
local changed = vim.json.encode(source)
fs.write(tmp .. '/resources/' .. name, changed)
manifest.bundle.files[name] = { size = #changed, sha256 = vim.fn.sha256(changed) }
manifest.bundle.id = fs.index_id(manifest.bundle.files)
fs.write(tmp .. '/resources/manifest.json', vim.json.encode(manifest))
local write = fs.write
fs.write = function(path, value)
  if path:match('/state%.json$') then error('injected state write failure') end
  return write(path, value)
end
reject('failed state publication')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '没有可用的信息', 'failed commit leaked new catalogs')
fs.write = write
assert(refresh().ok, 'valid resource update failed')
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '新资源已生效')
assert(zh.status().help.chinese_help:find(manifest.bundle.id, 1, true), 'Help did not use same resource generation')
local fallback = { kind = 'update', path = tmp }
fs.write(tmp .. '/resources/' .. name, bytes .. 'broken')
if vim.fn.exists('##PackChanged') == 1 then
  vim.api.nvim_exec_autocmds('PackChanged', { data = fallback })
else
  zh.refresh()
end
assert(vim.wait(5000, function() return zh.status().runtime.status == 'error' end, 20))
assert(zh.translate({ domain = 'nvim-ui', msgid = 'No information available' }) == '新资源已生效', 'failed event lost last good translations')
paths.root = original_root
vim.fn.delete(tmp, 'rf')
print('RESOURCE_SYNC_SPEC=PASS checksum schema symlink immutable_snapshot coordinated_help invalid_update_keeps_old')
