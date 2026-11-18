local M = {}

local adapters = {
  require('nvim-zh.adapters.which_key'),
  require('nvim-zh.adapters.telescope'),
  require('nvim-zh.adapters.nvim_tree'),
  {
    name = 'lazy.nvim',
    modules = { 'lazy' },
    attach = function() end,
    detach = function() end,
    info = function(ctx)
      return {
        active = ctx.enabled() and ctx.lazy_load(),
        reason = ctx.lazy_load() and 'shared_notify_and_lazy_load' or 'disabled',
        seam = 'vim.notify; User LazyLoad',
        domain = 'nvim-ui',
        supported_commit = '306a05526ada86a7b30af95c5cc81ffba93fef97',
      }
    end,
  },
  {
    name = 'nvim-cmp',
    modules = { 'cmp' },
    attach = function() end,
    detach = function() end,
    info = function()
      return {
        active = false,
        reason = 'inventory_only_no_cmp_owned_fixed_labels',
        seam = 'none',
        domain = 'nvim-cmp',
        supported_commit = '2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3',
      }
    end,
  },
}

local config = { auto = false, lazy_load = true, disabled = {} }
local AUGROUP = 'NvimZhPluginLateLoad'

local function enabled(name)
  if not config.auto then return false end
  for _, disabled in ipairs(config.disabled or {}) do
    if disabled == name then return false end
  end
  return true
end

local function context(adapter)
  return {
    enabled = function() return enabled(adapter.name) end,
    lazy_load = function() return config.auto and config.lazy_load end,
    translate = require('nvim-zh.adapters.common').translate,
    register_source = function(spec)
      return require('nvim-zh.ui').register_source(spec)
    end,
  }
end

local function attach_one(adapter)
  local ctx = context(adapter)
  if ctx.enabled() then adapter.attach(ctx) else adapter.detach() end
end

local function clear_lazy_load()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

local function setup_lazy_load()
  clear_lazy_load()
  if not config.auto or not config.lazy_load then return end
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LazyLoad',
    desc = 'nvim-zh: adapt supported plugins after lazy.nvim loads them',
    callback = function(event)
      for _, adapter in ipairs(adapters) do
        if adapter.lazy_name == event.data then attach_one(adapter) end
      end
    end,
  })
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  setup_lazy_load()
  for _, adapter in ipairs(adapters) do attach_one(adapter) end
end

function M.teardown()
  config = { auto = false, lazy_load = false, disabled = {} }
  clear_lazy_load()
  for _, adapter in ipairs(adapters) do adapter.detach() end
end

function M.loaded_signature()
  local values = {}
  for _, adapter in ipairs(adapters) do
    values[#values + 1] = adapter.name
    if adapter.signature then
      values[#values + 1] = adapter.signature()
    else
      for _, name in ipairs(adapter.modules or {}) do
        values[#values + 1] = tostring(package.loaded[name])
      end
    end
  end
  return table.concat(values, ':')
end

function M.info()
  local result = {}
  for _, adapter in ipairs(adapters) do
    local ctx = context(adapter)
    local info = adapter.info(ctx) or {}
    info.enabled = ctx.enabled()
    result[adapter.name] = info
  end
  return result
end

return M
