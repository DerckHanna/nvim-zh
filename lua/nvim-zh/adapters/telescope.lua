local common = require('nvim-zh.adapters.common')

local M = {
  name = 'telescope',
  lazy_name = 'telescope.nvim',
}

local DOMAIN = 'telescope'
local COMMIT = '40aedd8a68c78a656a10a8d62d80c54af59420fb'
local unpack = table.unpack or unpack
local attached = false
local ctx
local release_notification
local find_pre_group

local slots = {
  window = {
    module = 'telescope.pickers.window',
    method = 'get_initial_window_options',
    records = {},
  },
  previewer = {
    module = 'telescope.previewers.previewer',
    method = 'title',
    records = {},
  },
  pickers = {
    module = 'telescope.pickers',
    method = 'new',
    records = {},
  },
}

local function enabled(slot, generation)
  return attached and ctx and ctx.enabled() and slot.generation == generation
end

local function translate(text)
  return ctx.translate(DOMAIN, 'title', text)
end

local sync

local factories = {}

function factories.window(original, generation)
  return function(...)
    local returns = common.pack(original(...))
    local slot = slots.window
    if not enabled(slot, generation) or type(returns[1]) ~= 'table' then
      return unpack(returns, 1, returns.n)
    end

    -- This fixed Telescope API constructs display-only window options. Project
    -- their titles without mutating the picker or the original returned tables.
    local projection = common.copy(returns[1])
    for _, name in ipairs({ 'prompt', 'results', 'preview' }) do
      local section = returns[1][name]
      if type(section) == 'table' then
        local copy = common.copy(section)
        copy.title = translate(section.title)
        projection[name] = copy
      end
    end
    returns[1] = projection
    return unpack(returns, 1, returns.n)
  end
end

function factories.previewer(original, generation)
  return function(...)
    local returns = common.pack(original(...))
    if enabled(slots.previewer, generation) and type(returns[1]) == 'string' then
      returns[1] = translate(returns[1])
    end
    return unpack(returns, 1, returns.n)
  end
end

function factories.pickers(original, generation)
  return function(...)
    local slot = slots.pickers
    if enabled(slot, generation) then
      -- Builtins normally load previewers immediately before pickers.new. Sync
      -- here so their initial title query and subsequent refresh both see the
      -- owned wrapper, without requiring an absent plugin module ourselves.
      sync(slots.window)
      sync(slots.previewer)
    end
    local returns = common.pack(original(...))
    if enabled(slot, generation) then
      sync(slots.window)
      sync(slots.previewer)
    end
    return unpack(returns, 1, returns.n)
  end
end

slots.window.factory = factories.window
slots.previewer.factory = factories.previewer
slots.pickers.factory = factories.pickers

sync = function(slot)
  local current = package.loaded[slot.module]
  if current ~= slot.generation then
    if slot.generation ~= nil then
      -- Invalidate closures retained by other modules before restoring the old
      -- generation. External replacements are never reclaimed or overwritten.
      local previous = slot.generation
      slot.generation = nil
      common.unwrap(slot.records, slot.method)
      slot.generation = previous
    end

    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then
      if current ~= nil and current ~= false then
        slot.records[slot.method] = { active = false, reason = 'unsupported_api' }
      end
      return
    end
  end

  if type(current) ~= 'table' then return end
  -- common.wrap also handles reattaching after our owned wrapper was removed,
  -- repeated setup, and same-generation external replacement.
  common.wrap(slot.records, slot.method,
    function() return current[slot.method] end,
    function(value) current[slot.method] = value end,
    function(original) return slot.factory(original, current) end)
end

local function sync_all()
  sync(slots.window)
  sync(slots.previewer)
  sync(slots.pickers)
end

-- The pinned pickers.lua fires User TelescopeFindPre immediately before
-- create_layout(), after pickers.new already ran. It is the last public boundary
-- where the window/previewer modules are guaranteed loaded, so the very first
-- picker of a session gets the same display projection as later ones.
local function ensure_find_pre()
  if find_pre_group then return end
  find_pre_group = vim.api.nvim_create_augroup('NvimZhTelescopeFindPre', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = find_pre_group,
    pattern = 'TelescopeFindPre',
    desc = 'nvim-zh: project Telescope window titles before the first layout',
    callback = function()
      if attached and ctx and ctx.enabled() then
        sync(slots.window)
        sync(slots.previewer)
      end
    end,
  })
end

function M.attach(next_ctx)
  if not next_ctx.enabled() then
    M.detach()
    return
  end
  ctx = next_ctx
  attached = true
  if not release_notification then
    release_notification = ctx.register_source({
      title = 'telescope.nvim',
      domain = DOMAIN,
      context = 'notification',
    })
  end
  ensure_find_pre()
  sync_all()
end

function M.detach()
  attached = false
  if find_pre_group then
    pcall(vim.api.nvim_del_augroup_by_id, find_pre_group)
    find_pre_group = nil
  end
  if release_notification then
    local release = release_notification
    release_notification = nil
    release()
  end
  for _, slot in pairs(slots) do
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
  end
end

local function seam_info(slot)
  local current = package.loaded[slot.module]
  if current == nil or current == false then
    return { active = false, reason = 'not_loaded' }
  end
  if current ~= slot.generation then
    return { active = false, reason = 'stale_generation' }
  end
  return {
    active = attached and common.active(slot.records, slot.method) or false,
    reason = common.reason(slot.records, slot.method),
  }
end

function M.info(current_ctx)
  local window = seam_info(slots.window)
  local previewer = seam_info(slots.previewer)
  local lifecycle = seam_info(slots.pickers)
  local function loaded(slot)
    local module = package.loaded[slot.module]
    return module ~= nil and module ~= false
  end
  local any_loaded = loaded(slots.window) or loaded(slots.previewer) or loaded(slots.pickers)
  local display_active = current_ctx.enabled() and attached
    and (window.active or previewer.active) or false
  local degraded = window.reason == 'external_override'
    or previewer.reason == 'external_override'
    or lifecycle.reason == 'external_override'
    or window.reason == 'unsupported_api'
    or previewer.reason == 'unsupported_api'
    or lifecycle.reason == 'unsupported_api'
  local reason
  if not attached or not current_ctx.enabled() then
    reason = 'disabled'
  elseif not any_loaded then
    reason = 'not_loaded'
  elseif display_active then
    reason = degraded and 'partially_active' or 'attached'
  elseif lifecycle.active then
    reason = 'lifecycle_only'
  elseif degraded then
    reason = 'external_override'
  else
    reason = window.reason ~= 'not_loaded' and window.reason
      or previewer.reason ~= 'not_loaded' and previewer.reason
      or lifecycle.reason
  end

  return {
    active = display_active,
    reason = reason,
    seam = 'pickers.window.get_initial_window_options; previewers.previewer.title; pickers.new(lifecycle); vim.notify title source',
    domain = DOMAIN,
    supported_commit = COMMIT,
    window = window,
    previewer = previewer,
    lifecycle = lifecycle,
    notification = {
      active = release_notification ~= nil,
      title = 'telescope.nvim',
      context = 'notification',
    },
    internal_titles = 'preserved',
    refine_change_title = 'uncovered_no_safe_seam',
    uncovered = 'actions.generate.refine border:change_title has no safe display-only seam; final refined titles stay unchanged',
  }
end

function M.signature()
  local values = {}
  for _, key in ipairs({ 'window', 'previewer', 'pickers' }) do
    local slot = slots[key]
    local module = package.loaded[slot.module]
    values[#values + 1] = slot.module
    values[#values + 1] = tostring(module)
    values[#values + 1] = type(module) == 'table' and tostring(module[slot.method]) or 'missing'
  end
  return table.concat(values, ':')
end

return M
