local common = require('nvim-zh.adapters.common')

local M = {
  name = 'nvim-tree',
  lazy_name = 'nvim-tree.lua',
}

local DOMAIN = 'nvim-tree'
local PREFIX = 'nvim-tree: '
local SUPPORTED_COMMIT = '69eb0c34ed3d836d5a0d92d913b77dd73b054f2f'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  tree = nil,
  keymap = nil,
  tree_records = {},
  keymap_records = {},
  release_source = nil,
  source_error = nil,
  load_error = nil,
}

local attach_keymap

local function restore_tree()
  common.unwrap(state.tree_records, 'setup', 'disabled')
end

local function restore_keymap()
  common.unwrap(state.keymap_records, 'on_attach_default', 'disabled')
end

local function sync_tree(tree)
  if state.tree ~= tree then
    restore_tree()
    state.tree_records = {}
    state.tree = tree
  end
  if type(tree) ~= 'table' then return end

  common.wrap(state.tree_records, 'setup', function()
    return tree.setup
  end, function(value)
    tree.setup = value
  end, function(original)
    local wrapper
    wrapper = function(...)
      -- The fixed setup only installs configuration; it does not attach a tree
      -- buffer. Preserve its call contract, then adapt before the first attach.
      local results = common.pack(original(...))
      if state.enabled and state.tree == tree and tree.setup == wrapper then
        local ok, err = pcall(attach_keymap)
        if not ok then state.load_error = tostring(err) end
      end
      return unpack(results, 1, results.n)
    end
    return wrapper
  end)
end

local function translate_default_set(original_set)
  return function(mode, lhs, rhs, opts)
    if type(opts) ~= 'table' or type(opts.desc) ~= 'string'
      or opts.desc:sub(1, #PREFIX) ~= PREFIX then
      return original_set(mode, lhs, rhs, opts)
    end

    local suffix = opts.desc:sub(#PREFIX + 1)
    local translated = state.ctx.translate(DOMAIN, 'mapping', suffix)
    if translated == suffix then return original_set(mode, lhs, rhs, opts) end

    local copy = common.copy(opts)
    copy.desc = PREFIX .. translated
    return original_set(mode, lhs, rhs, copy)
  end
end

local function sync_keymap(keymap)
  if state.keymap ~= keymap then
    restore_keymap()
    state.keymap_records = {}
    state.keymap = keymap
  end
  if type(keymap) ~= 'table' then return end

  common.wrap(state.keymap_records, 'on_attach_default', function()
    return keymap.on_attach_default
  end, function(value)
    keymap.on_attach_default = value
  end, function(original)
    local wrapper
    wrapper = function(...)
      -- Retained callbacks must be transparent when off, replaced, or stale.
      if not state.enabled or state.keymap ~= keymap or keymap.on_attach_default ~= wrapper then
        return original(...)
      end

      local original_set = vim.keymap.set
      local translated_set = translate_default_set(original_set)
      vim.keymap.set = translated_set
      local results = common.pack(pcall(original, ...))
      if vim.keymap.set == translated_set then vim.keymap.set = original_set end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
    return wrapper
  end)
end

attach_keymap = function()
  state.load_error = nil
  local keymap = package.loaded['nvim-tree.keymap']

  -- At the pinned commit keymap.lua only requires the already-loaded config and
  -- defines functions. Never load nvim-tree itself; load this leaf module only
  -- after the plugin is loaded and setup has made config.g available.
  if keymap == nil then
    local tree = package.loaded['nvim-tree']
    local config = package.loaded['nvim-tree.config']
    if type(tree) == 'table' and type(config) == 'table' and type(config.g) == 'table' then
      local ok, loaded = pcall(require, 'nvim-tree.keymap')
      if ok then
        keymap = loaded
      else
        state.load_error = tostring(loaded)
      end
    end
  end

  sync_keymap(keymap)
end

local function register_source(ctx)
  if state.release_source or state.source_error then return end
  local ok, release = pcall(ctx.register_source, {
    title = 'NvimTree',
    domain = DOMAIN,
    context = 'notification',
    prefix = '[NvimTree]',
  })
  if ok then
    state.release_source = release
  else
    state.source_error = tostring(release)
  end
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = ctx.enabled()
  if not state.enabled then return M.detach() end

  register_source(ctx)
  sync_tree(package.loaded['nvim-tree'])
  attach_keymap()
end

function M.detach()
  state.enabled = false
  if state.release_source then
    state.release_source()
    state.release_source = nil
  end
  state.source_error = nil
  -- Same-module external replacements stay owned by the caller across a later
  -- re-attach. Only sync_* on an actual module-table generation clears records.
  restore_tree()
  restore_keymap()
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local tree = package.loaded['nvim-tree']
  local keymap = package.loaded['nvim-tree.keymap']
  local config = package.loaded['nvim-tree.config']
  local active = enabled and common.active(state.keymap_records, 'on_attach_default')
  local keymap_reason = common.reason(state.keymap_records, 'on_attach_default')
  local setup_reason = common.reason(state.tree_records, 'setup')
  local reason

  if not enabled then
    reason = 'disabled'
  elseif keymap_reason == 'external_override' or setup_reason == 'external_override' then
    reason = 'external_override'
  elseif active then
    reason = nil
  elseif state.load_error then
    reason = 'keymap_load_failed'
  elseif type(tree) ~= 'table' then
    reason = 'not_loaded'
  elseif type(config) ~= 'table' or type(config.g) ~= 'table' then
    reason = 'waiting_for_setup'
  elseif type(keymap) ~= 'table' then
    reason = 'keymap_not_loaded'
  else
    reason = keymap_reason
  end

  return {
    active = active,
    reason = reason,
    seam = 'keymap.on_attach_default; setup lifecycle; exact vim.notify title',
    domain = DOMAIN,
    supported_commit = SUPPORTED_COMMIT,
    version_related = 'pinned keymap.lua is function-definition-only; leaf require is allowed only after tree setup',
    setup_active = enabled and common.active(state.tree_records, 'setup'),
    setup_reason = setup_reason,
    keymap_reason = keymap_reason,
    notification_source = state.release_source ~= nil,
    notification_error = state.source_error,
    load_error = state.load_error,
    existing_buffers = 'not_reattached',
  }
end

function M.signature()
  local tree = package.loaded['nvim-tree']
  local keymap = package.loaded['nvim-tree.keymap']
  return table.concat({
    tostring(tree),
    type(tree) == 'table' and tostring(tree.setup) or '',
    tostring(keymap),
    type(keymap) == 'table' and tostring(keymap.on_attach_default) or '',
  }, ':')
end

return M
