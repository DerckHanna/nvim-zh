local root = assert(vim.env.NVIM_ZH_ROOT)
vim.opt.rtp:prepend(root)
local zh, packs = require('nvim-zh'), require('nvim-zh.packs')
local store = require('nvim-zh.pack_store')
local mode = assert(vim.env.NVIM_ZH_P3_MODE)
local historical = assert(vim.env.NVIM_ZH_P3_HISTORICAL)
local candidate = assert(vim.env.NVIM_ZH_P3_CANDIDATE)
local index_path = candidate .. '/catalog.json'
local ids = { 'which-key', 'telescope', 'nvim-tree', 'nvim-dap', 'nvim-dap-ui', 'nvim-dap-view' }
local index = vim.json.decode(table.concat(vim.fn.readfile(index_path), '\n'))
local targets, urls, expected = {}, {}, {}
local request_count = 0

local function artifact(dir, id) return dir .. '/' .. id .. '-zh_CN.json' end
for _, row in ipairs(index.packages) do
  if vim.tbl_contains(ids, row.id) then
    urls[row.url] = artifact(row.sdk == 1 and historical or candidate, row.id)
    targets[row.id] = { spec = { src = row.repository }, rev = row.targets[1] }
    expected[row.id .. '@' .. row.version] = row
  end
end
vim.pack.get = function() return vim.tbl_values(targets) end

vim.system = function(argv, _, done)
  request_count = request_count + 1
  assert(mode == 'remote' or mode == 'legacy', 'unexpected subprocess in offline mode')
  assert(argv[1] == 'curl' and vim.tbl_contains(argv, '=https'))
  local url = argv[assert(vim.fn.index(argv, '--url') >= 0 and vim.fn.index(argv, '--url') + 2)]
  local output = argv[assert(vim.fn.index(argv, '--output') >= 0 and vim.fn.index(argv, '--output') + 2)]
  local path = urls[url] or (url:match('/packs/catalog%.json$') and index_path)
  assert(path and vim.uv.fs_copyfile(path, output), 'missing remote fixture: ' .. url)
  vim.schedule(function() done({ code = 0 }) end)
  return { kill = function() end }
end

local function wait_action(start)
  local result
  start(function(ok, why) result = { ok, why } end)
  assert(vim.wait(5000, function() return result ~= nil end), 'operation timed out')
  assert(result[1], result[2])
end

local function state(id, selected, active, restart)
  local row = assert(zh.status().packs[id], id)
  assert(row.selected == selected and row.active == active and (row.restart == true) == restart,
    id .. ': ' .. vim.inspect(row))
  return row
end

local function import(id, dir, sdk)
  local path = artifact(dir, id)
  local item = packs.inspect(path)
  local published = expected[id .. '@' .. item.version]
  assert(item.id == id and item.sdk == sdk and item.lua and item.sha256 == published.sha256)
  assert(packs.import(path, true, item.sha256) == id)
end

if mode == 'measure' then
  local id = assert(vim.env.NVIM_ZH_P3_ID)
  local sdk = assert(tonumber(vim.env.NVIM_ZH_P3_SDK))
  local record = expected[id .. '@' .. (sdk == 1 and '0.1.0' or '0.2.0')]
  local path = artifact(sdk == 1 and historical or candidate, id)
  local bytes = require('nvim-zh.fs').read(path, store.limit)
  store.stage(bytes, record, true)
  collectgarbage('collect')
  local rss = vim.uv.resident_set_memory()
  local lua = collectgarbage('count')
  local t0 = vim.uv.hrtime()
  local asset = store.load(id, vim.tbl_extend('force', {}, record, { allow_lua = true }))
  local elapsed = (vim.uv.hrtime() - t0) / 1e6
  assert(asset.manifest.sdk == sdk and asset.entry and asset.tags and next(asset.tags))
  collectgarbage('collect')
  print(vim.json.encode({ id = id, sdk = sdk, bytes = #bytes, load_ms = elapsed,
    rss_kib = (vim.uv.resident_set_memory() - rss) / 1024, lua_kib = collectgarbage('count') - lua }))
  return
end

zh.setup({ modules = { core = { enabled = false } } })
assert(vim.wait(20000, function() return zh.status().runtime.status ~= 'syncing' end))
assert(zh.status().runtime.status == 'ok' or zh.status().runtime.status == 'degraded', vim.inspect(zh.status().runtime))
if mode == 'legacy' then
  wait_action(packs.refresh_catalog)
  local rows = packs.rows()
  for _, id in ipairs(ids) do
    local row = assert(vim.iter(rows):find(function(value) return value.id == id end))
    assert(#row.options == 1 and row.options[1].sdk == 1 and row.options[1].version == '0.1.0', vim.inspect(row))
    wait_action(function(done) packs.install(row.options[1], done) end)
    state(id, '0.1.0', '0.1.0', false)
  end
elseif mode == 'remote' then
  wait_action(packs.refresh_catalog)
  for _, id in ipairs(ids) do
    local row = assert(vim.iter(packs.rows()):find(function(value) return value.id == id end))
    assert(row.update.version == '0.2.0')
    local sdk1 = vim.iter(row.options):find(function(value) return value.sdk == 1 end)
    wait_action(function(done) packs.install(sdk1, done) end)
    wait_action(function(done) packs.install(row.update, done) end)
    state(id, '0.2.0', '0.1.0', true)
  end
elseif mode == 'offline' then
  for _, id in ipairs(ids) do
    assert(not pcall(packs.import, artifact(candidate, id), false))
    import(id, historical, 1)
    import(id, candidate, 2)
    state(id, '0.2.0', '0.1.0', true)
  end
  assert(packs.import(artifact(candidate, 'nvim-cmp'), true) == 'nvim-cmp')
  state('nvim-cmp', '0.2.0', '0.2.0', false)
elseif mode == 'fresh' or mode == 'corrupt' or mode == 'rollback' or mode == 'rolled_back' then
  for _, id in ipairs(ids) do
    if mode == 'corrupt' then
      assert(state(id, '0.2.0', '0.1.0', false).error)
    elseif mode == 'rolled_back' then
      state(id, '0.1.0', '0.1.0', false)
    else
      state(id, '0.2.0', '0.2.0', false)
      if mode == 'rollback' then
        packs.change(id, 'rollback')
        state(id, '0.1.0', '0.2.0', true)
      end
    end
  end
else
  error('unknown mode: ' .. mode)
end
if mode ~= 'remote' and mode ~= 'legacy' then assert(request_count == 0) end
print('PLUGIN_PACK_MIGRATION=PASS mode=' .. mode .. ' packs=' .. #ids .. ' requests=' .. request_count)
