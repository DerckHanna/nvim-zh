local common = require('nvim-zh.adapters.common')

local unpack = table.unpack or unpack
local COMMIT = '3aab2147e74890957785941f0c1ad87d0a44c15a'

local M = {
  name = 'which-key',
  lazy_name = 'which-key.nvim',
}

local state = {
  active = false,
  reason = 'not_initialized',
}

local function find_formatter(list, formatter)
  for index, value in ipairs(list) do
    if value == formatter then return index end
  end
  return nil
end

-- A formatter belongs only to the list generation that received it. Keeping its
-- identity lets us clean an old module/list without reclaiming a replacement.
local function clear_formatter(reason, preserve_external)
  local external_config = preserve_external
    and ((state.reason == 'external_override' and state.config) or state.external_config) or nil
  if state.list and state.formatter then
    local index = find_formatter(state.list, state.formatter)
    if index then table.remove(state.list, index) end
  end
  state.config, state.list, state.formatter = nil, nil, nil
  state.external_config = external_config
  state.active, state.reason = false, reason or 'disabled'
end

local function clear_setup(reason, preserve_external)
  local generation = state.setup
  if not generation then return end
  generation.valid = false
  common.unwrap(generation.hooks, 'setup', reason or 'disabled')
  local record = generation.hooks.setup
  if preserve_external and record and record.reason == 'external_override' then
    state.setup = generation
  else
    state.setup = nil
  end
end

local function attach_formatter()
  local config = package.loaded['which-key.config']
  if state.external_config and state.external_config ~= config then state.external_config = nil end
  if state.config and state.config ~= config then clear_formatter('module_replaced', false) end
  if type(config) ~= 'table' then
    state.active, state.reason = false, 'not_loaded'
    return
  end
  if type(config.replace) ~= 'table' or type(config.replace.desc) ~= 'table' then
    state.active, state.reason = false, 'unsupported_api'
    return
  end

  local list = config.replace.desc
  if state.formatter then
    if state.list == list and find_formatter(list, state.formatter) then
      state.active, state.reason = true, nil
    else
      -- Direct replacement/removal is an external choice. Only a subsequent
      -- public setup call may deliberately attach to a rebuilt list.
      state.active, state.reason = false, 'external_override'
    end
    return
  end
  if state.external_config == config then
    state.active, state.reason = false, 'external_override'
    return
  end

  local formatter
  formatter = function(text)
    local ctx = state.ctx
    if not ctx or not ctx.enabled() or not state.active
      or state.config ~= config or state.list ~= list or state.formatter ~= formatter then
      return text
    end
    local ok, translated = pcall(ctx.translate, 'which-key', 'desc', text)
    return ok and type(translated) == 'string' and translated or text
  end
  table.insert(list, formatter)
  state.config, state.list, state.formatter = config, list, formatter
  state.active, state.reason = true, nil
end

local function attach_setup()
  local wk = package.loaded['which-key']
  if state.setup and state.setup.module ~= wk then clear_setup('module_replaced', false) end
  if type(wk) ~= 'table' then return end

  local generation = state.setup
  if not generation then
    generation = { module = wk, hooks = {}, valid = true }
    state.setup = generation
  end

  generation.valid = true
  common.wrap(generation.hooks, 'setup', function()
    return wk.setup
  end, function(value)
    wk.setup = value
  end, function(original)
    local wrapper
    wrapper = function(...)
      -- Do not turn an original setup failure into a successful reattach.
      local results = common.pack(original(...))
      if generation.valid and state.setup == generation and wk.setup == wrapper then
        clear_formatter('setup', false)
        if state.ctx and state.ctx.enabled() then
          attach_formatter()
        else
          state.reason = 'disabled'
        end
      end
      return unpack(results, 1, results.n)
    end
    return wrapper
  end)
end

function M.attach(ctx)
  state.ctx = ctx
  if not ctx.enabled() then
    M.detach()
    return
  end

  if not state.source_release then
    state.source_release = ctx.register_source({
      title = 'which-key.nvim',
      domain = 'which-key',
      context = 'notification',
    })
  end
  attach_setup()
  attach_formatter()
end

function M.detach()
  if state.source_release then
    local release = state.source_release
    state.source_release = nil
    release()
  end
  clear_setup('disabled', true)
  clear_formatter('disabled', true)
end

function M.info(ctx)
  local enabled = ctx.enabled()
  local setup_reason = state.setup and common.reason(state.setup.hooks, 'setup')
    or (type(package.loaded['which-key']) == 'table' and 'not_initialized' or 'not_loaded')
  local reason = not enabled and 'disabled'
    or setup_reason == 'external_override' and 'external_override'
    or state.reason or 'not_initialized'
  return {
    active = enabled and state.active == true,
    reason = reason,
    seam = 'replace.desc',
    setup_seam = 'setup',
    setup_active = enabled and state.setup ~= nil and common.active(state.setup.hooks, 'setup'),
    setup_reason = setup_reason,
    notification_seam = 'vim.notify:title',
    notification_active = enabled and state.source_release ~= nil,
    domain = 'which-key',
    supported_commit = COMMIT,
    provenance = 'replace.desc has no mapping provenance; identical user descriptions may display built-in translations',
    excluded = 'footer/private buffers; raw mappings, keys, rhs, paths and user data',
  }
end

function M.signature()
  local wk = package.loaded['which-key']
  local config = package.loaded['which-key.config']
  local replace = type(config) == 'table' and config.replace or nil
  return table.concat({
    tostring(wk),
    tostring(type(wk) == 'table' and wk.setup or nil),
    tostring(config),
    tostring(replace),
    tostring(type(replace) == 'table' and replace.desc or nil),
  }, ':')
end

return M
