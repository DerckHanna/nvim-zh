local zh = require('nvim-zh')
zh.setup({ modules = { core = { enabled = false } } })
local snapshot = zh.status()
local index = require('nvim-zh.adapters.index')
assert(snapshot.config.modules.plugins.auto, 'adapters are disabled by default')
assert(type(snapshot.version.running_version) == 'string' and snapshot.version.running_version ~= '')
local catalog = require('nvim-zh.catalog')
for id, spec in pairs(index) do
  local state = assert(snapshot.adapters[id], 'missing adapter status: ' .. id)
  assert(spec.targets.baseline.commit == state.targets.baseline, id .. ' manifest/version mismatch')
  assert(not state.active, id .. ' active without a loaded module')
  if spec.status == 'implemented' then
    assert(state.reason == 'not_loaded', id .. ' absent without not_loaded status')
    local entries = assert(catalog.get(spec.domain), id .. ' missing catalog')
    assert(entries.total > 0, id .. ' has an empty catalog')
  else
    assert(state.reason == 'inventory_only', id .. ' missing inventory-only state')
  end
end

local refreshed
zh.refresh(function(result) refreshed = result end)
assert(refreshed and refreshed.ok and refreshed.status == 'ok', 'resource/config refresh failed')
assert(vim.fn.exists(':NvimZhReload') == 0 and vim.fn.exists(':NvimZhInfo') == 0, 'retired command still registered')
print(('PLUGIN_INTEGRATION_SPEC=PASS adapters=%d'):format(vim.tbl_count(index)))
