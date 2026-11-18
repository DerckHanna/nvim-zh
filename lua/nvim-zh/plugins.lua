local M = {}

local adapters = {
  require('nvim-zh.adapters.which_key'),
  require('nvim-zh.adapters.telescope'),
  require('nvim-zh.adapters.nvim_tree'),
  require('nvim-zh.adapters.nvim_dap'),
  require('nvim-zh.adapters.nvim_dap_ui'),
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
-- Some supported plugins finish loading after nvim-zh setup without emitting
-- User LazyLoad (e.g. which-key auto-setups on a 500ms timer). Their module
-- signature only changes once loading completes, so a bounded startup sweep
-- re-attaches adapters when that happens. It never forces a plugin to load and
-- stops as soon as the signature is stable; FocusGained/BufEnter and LazyLoad
-- remain the long-term boundaries.
local startup_timers = {}
local startup_signature
local STARTUP_DELAYS = { 300, 800, 1600 }

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

local function clear_startup_timers()
  for _, timer in ipairs(startup_timers) do
    timer:stop()
    if not timer:is_closing() then timer:close() end
  end
  startup_timers = {}
  startup_signature = nil
end

local function attach_all()
  for _, adapter in ipairs(adapters) do attach_one(adapter) end
end

-- Re-attach only when the loaded-module signature actually changed, so a stable
-- session does no repeated work and an external replacement is never reclaimed.
local function startup_sweep()
  if not config.auto then return end
  local signature = M.loaded_signature()
  if signature == startup_signature then return end
  startup_signature = signature
  attach_all()
end

local function schedule_startup_sweep()
  clear_startup_timers()
  if not config.auto then return end
  startup_signature = M.loaded_signature()
  for _, delay in ipairs(STARTUP_DELAYS) do
    local timer = (vim.uv or vim.loop).new_timer()
    startup_timers[#startup_timers + 1] = timer
    -- One-shot timers stop themselves; handles are closed centrally on the next
    -- setup or teardown, never from inside a running callback.
    timer:start(delay, 0, vim.schedule_wrap(function()
      timer:stop()
      startup_sweep()
    end))
  end
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  setup_lazy_load()
  attach_all()
  schedule_startup_sweep()
end

function M.teardown()
  config = { auto = false, lazy_load = false, disabled = {} }
  clear_lazy_load()
  clear_startup_timers()
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
