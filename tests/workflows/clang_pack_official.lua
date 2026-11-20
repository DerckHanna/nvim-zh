-- Explicit network probe. Use a fresh XDG data directory for the online run.
vim.opt.rtp:prepend(assert(vim.env.NVIM_ZH_ROOT))
vim.cmd('runtime plugin/nvim-zh.lua')
local zh = require('nvim-zh')
local store = require('nvim-zh.pack_store')
zh.setup({ modules = { core = { enabled = false }, plugins = { auto = false } } })
assert(zh.status().runtime.status == 'ok', vim.inspect(zh.status().runtime))
local function state()
  return zh.status().packs.clangd or {}
end
local function active(version)
  return state().active == version and (not state().job or state().job.finished)
end
local mode = assert(vim.env.NVIM_ZH_OFFICIAL_MODE)
if mode == 'offline' then
  assert(active('0.1.1'), vim.inspect(state()))
  local system = vim.system
  vim.system = function(argv, ...)
    assert(argv[1] ~= 'curl', 'rollback attempted a download')
    return system(argv, ...)
  end
  vim.cmd('NvimZhPacks rollback clangd')
  assert(active('0.1.0') and state().previous == '0.1.1', vim.inspect(state()))
  print('OFFICIAL_CLANGD_ROLLBACK=PASS 0.1.1 to 0.1.0 without download')
elseif mode == 'damaged' then
  assert(active('0.1.0') and state().selected == '0.1.1' and state().error, vim.inspect(state()))
  vim.cmd('NvimZhPacks rollback clangd')
  assert(active('0.1.0') and state().selected == '0.1.0' and not state().error, vim.inspect(state()))
  print('OFFICIAL_CLANGD_DAMAGED=PASS verified previous snapshot selected after damage')
else
  assert(not state().selected, vim.inspect(state()))
  vim.cmd('NvimZhPacks install official:clangd@0.1.0')
  assert(vim.wait(60000, function() return active('0.1.0') end, 50), vim.inspect(state()))
  vim.cmd('NvimZhPacks update clangd')
  assert(vim.wait(60000, function() return active('0.1.1') end, 50), vim.inspect(state()))
  assert(state().previous == '0.1.0')
  vim.cmd('NvimZhPacks disable clangd')
  assert(state().enabled == false and not state().active, vim.inspect(state()))
  vim.cmd('NvimZhPacks enable clangd')
  assert(active('0.1.1'), vim.inspect(state()))
  print('OFFICIAL_CLANGD_LIFECYCLE=PASS install 0.1.0 update 0.1.1 pause resume')
  local selected = store.record('clangd').selected
  assert(selected.source == 'official')
  vim.fn.writefile({ selected.sha256 }, assert(vim.env.NVIM_ZH_OFFICIAL_DIGEST))
end
