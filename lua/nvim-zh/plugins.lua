local M = {}

local engine = require('nvim-zh.engine')
local config = { auto = false, lazy_load = true, disabled = {} }
local states = { ['which-key'] = {}, telescope = {}, ['nvim-tree'] = {} }
local unpack = table.unpack or unpack
local AUGROUP = 'NvimZhPluginLateLoad'

local function pack(...) return { n = select('#', ...), ... } end

local function is_disabled(name)
  for _, disabled in ipairs(config.disabled or {}) do
    if disabled == name then return true end
  end
  return false
end

local function enabled(name) return config.auto and not is_disabled(name) end

local function translate(domain, context, text)
  if type(text) ~= 'string' or text == '' then return text end
  local ok, translated = pcall(engine.translate, {
    domain = domain,
    context = context,
    msgid = text,
    formatted = true,
  })
  if ok and type(translated) == 'string' then return translated end
  return text
end

local function find_formatter(list, fn)
  for index, formatter in ipairs(list) do
    if formatter == fn then return index end
  end
  return nil
end

local function teardown_which_key_formatter(state)
  if state.list and state.formatter then
    local index = find_formatter(state.list, state.formatter)
    if index then table.remove(state.list, index) end
  end
  state.list = nil
  state.formatter = nil
  state.active = false
  state.reason = 'disabled'
end

local function restore_which_key_setup(state)
  if not state.setup_wrapper then return end
  local wk = package.loaded['which-key']
  if type(wk) == 'table' and wk.setup == state.setup_wrapper then
    wk.setup = state.setup_original
    state.setup_wrapper, state.setup_original = nil, nil
  else
    state.setup_external = true
  end
end

local setup_which_key
local function setup_which_key_setup(state)
  if not enabled('which-key') then
    restore_which_key_setup(state)
    return
  end
  local wk = package.loaded['which-key']
  if type(wk) ~= 'table' or type(wk.setup) ~= 'function' then return end
  if state.setup_wrapper then
    state.setup_external = wk.setup ~= state.setup_wrapper
    return
  end
  local original = wk.setup
  state.setup_original = original
  state.setup_wrapper = function(...)
    local results = pack(original(...))
    -- This is a known, normal public setup call. Reattach only in this path;
    -- direct replacement of replace.desc remains an external override.
    teardown_which_key_formatter(state)
    setup_which_key(state)
    return unpack(results, 1, results.n)
  end
  state.setup_external = false
  wk.setup = state.setup_wrapper
end

setup_which_key = function(state, reattach)
  if not enabled('which-key') then
    teardown_which_key_formatter(state)
    restore_which_key_setup(state)
    return
  end
  local wk_config = package.loaded['which-key.config']
  if type(wk_config) ~= 'table' then
    state.active, state.reason = false, 'not_loaded'
    setup_which_key_setup(state)
    return
  end
  if type(wk_config.replace) ~= 'table' or type(wk_config.replace.desc) ~= 'table' then
    state.active, state.reason = false, 'unsupported_api'
    setup_which_key_setup(state)
    return
  end
  local list = wk_config.replace.desc
  if state.formatter and not reattach then
    if find_formatter(list, state.formatter) then
      state.list = list
      state.active, state.reason = true, nil
    else
      state.active, state.reason = false, 'external_override'
    end
    setup_which_key_setup(state)
    return
  end
  if reattach then teardown_which_key_formatter(state) end
  local formatter = function(text)
    if not enabled('which-key') then return text end
    return translate('which-key', 'desc', text)
  end
  table.insert(list, formatter)
  state.list, state.formatter = list, formatter
  state.active, state.reason = true, nil
  setup_which_key_setup(state)
end

local function telescope_titles(opts)
  if type(opts) ~= 'table' then return opts end
  local copy = {}
  for key, value in pairs(opts) do copy[key] = value end
  for _, key in ipairs({ 'prompt_title', 'results_title', 'preview_title' }) do
    if type(copy[key]) == 'string' then copy[key] = translate('telescope', 'title', copy[key]) end
  end
  return copy
end

local function restore_telescope(state)
  if state.wrapper then
    local pickers = package.loaded['telescope.pickers']
    if type(pickers) == 'table' and pickers.new == state.wrapper then
      pickers.new = state.original
      state.wrapper, state.original = nil, nil
      state.active, state.reason = false, 'disabled'
    else
      state.active, state.reason = false, 'external_override'
    end
  end
  if state.title_wrapper then
    local previewer = package.loaded['telescope.previewers.previewer']
    if type(previewer) == 'table' and previewer.title == state.title_wrapper then
      previewer.title = state.title_original
      state.title_wrapper, state.title_original = nil, nil
      state.title_active, state.title_reason = false, 'disabled'
    else
      state.title_active, state.title_reason = false, 'external_override'
    end
  end
end

local function setup_telescope_previewer(state)
  local previewer = package.loaded['telescope.previewers.previewer']
  if type(previewer) ~= 'table' then
    state.title_active, state.title_reason = false, 'not_loaded'
    return
  end
  if type(previewer.title) ~= 'function' then
    state.title_active, state.title_reason = false, 'unsupported_api'
    return
  end
  if state.title_wrapper then
    if previewer.title == state.title_wrapper then
      state.title_active, state.title_reason = true, nil
    else
      state.title_active, state.title_reason = false, 'external_override'
    end
    return
  end
  local original = previewer.title
  local wrapper = function(self, entry, dynamic)
    local title = original(self, entry, dynamic)
    if not enabled('telescope') then return title end
    return translate('telescope', 'title', title)
  end
  state.title_original, state.title_wrapper = original, wrapper
  state.title_active, state.title_reason = true, nil
  previewer.title = wrapper
end

local function setup_telescope(state)
  if not enabled('telescope') then
    restore_telescope(state)
    if not state.wrapper then state.active, state.reason = false, 'disabled' end
    if not state.title_wrapper then state.title_active, state.title_reason = false, 'disabled' end
    return
  end
  local pickers = package.loaded['telescope.pickers']
  if type(pickers) ~= 'table' then
    state.active, state.reason = false, 'not_loaded'
  elseif type(pickers.new) ~= 'function' then
    state.active, state.reason = false, 'unsupported_api'
  elseif state.wrapper then
    if pickers.new == state.wrapper then
      state.active, state.reason = true, nil
    else
      state.active, state.reason = false, 'external_override'
    end
  else
    local original = pickers.new
    local wrapper = function(opts, defaults)
      if not enabled('telescope') then return original(opts, defaults) end
      return original(telescope_titles(opts), telescope_titles(defaults))
    end
    state.original, state.wrapper = original, wrapper
    state.active, state.reason = true, nil
    pickers.new = wrapper
  end
  setup_telescope_previewer(state)
end

local function restore_nvim_tree(state)
  if not state.wrapper then return end
  local tree = package.loaded['nvim-tree']
  if type(tree) == 'table' and tree.setup == state.wrapper then
    tree.setup = state.original
    state.wrapper, state.original = nil, nil
    state.active, state.reason = false, 'disabled'
  else
    state.active, state.reason = false, 'external_override'
  end
end

local function translate_tree_opts(opts)
  if type(opts) ~= 'table' or type(opts.on_attach) ~= 'function' then return opts end
  local copy = {}
  for key, value in pairs(opts) do copy[key] = value end
  local on_attach = opts.on_attach
  copy.on_attach = function(...)
    if not enabled('nvim-tree') then return on_attach(...) end
    local original_set = vim.keymap.set
    if type(original_set) ~= 'function' then return on_attach(...) end
    local scoped_set
    scoped_set = function(mode, lhs, rhs, map_opts)
      if not enabled('nvim-tree') or type(map_opts) ~= 'table' or type(map_opts.desc) ~= 'string' then
        return original_set(mode, lhs, rhs, map_opts)
      end
      local map_copy = {}
      for key, value in pairs(map_opts) do map_copy[key] = value end
      map_copy.desc = translate('nvim-tree', 'mapping', map_opts.desc)
      return original_set(mode, lhs, rhs, map_copy)
    end
    vim.keymap.set = scoped_set
    local results = pack(pcall(on_attach, ...))
    if vim.keymap.set == scoped_set then vim.keymap.set = original_set end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
  return copy
end

local function setup_nvim_tree(state)
  if not enabled('nvim-tree') then
    restore_nvim_tree(state)
    if not state.wrapper then state.active, state.reason = false, 'disabled' end
    return
  end
  local tree = package.loaded['nvim-tree']
  if type(tree) ~= 'table' then
    state.active, state.reason = false, 'not_loaded'
    return
  end
  if type(tree.setup) ~= 'function' then
    state.active, state.reason = false, 'unsupported_api'
    return
  end
  if state.wrapper then
    if tree.setup == state.wrapper then
      state.active, state.reason = true, nil
    else
      state.active, state.reason = false, 'external_override'
    end
    return
  end
  local original = tree.setup
  local wrapper = function(opts, ...)
    if not enabled('nvim-tree') then return original(opts, ...) end
    return original(translate_tree_opts(opts), ...)
  end
  state.original, state.wrapper = original, wrapper
  state.active, state.reason = true, nil
  tree.setup = wrapper
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
      local name = event.data
      if name == 'which-key.nvim' then
        setup_which_key(states['which-key'])
      elseif name == 'telescope.nvim' then
        setup_telescope(states.telescope)
      elseif name == 'nvim-tree.lua' then
        setup_nvim_tree(states['nvim-tree'])
      end
    end,
  })
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  setup_lazy_load()
  setup_which_key(states['which-key'])
  setup_telescope(states.telescope)
  setup_nvim_tree(states['nvim-tree'])
end

function M.reload(next_config)
  config = vim.deepcopy(next_config or config)
  setup_lazy_load()
  setup_which_key(states['which-key'])
  local telescope = states.telescope
  local pickers = package.loaded['telescope.pickers']
  if telescope.wrapper and type(pickers) == 'table' and pickers.new == telescope.wrapper then
    restore_telescope(telescope)
  end
  setup_telescope(telescope)
  setup_nvim_tree(states['nvim-tree'])
end

function M.teardown()
  config = { auto = false, lazy_load = false, disabled = {} }
  clear_lazy_load()
  teardown_which_key_formatter(states['which-key'])
  restore_which_key_setup(states['which-key'])
  restore_telescope(states.telescope)
  restore_nvim_tree(states['nvim-tree'])
end

function M.info()
  local state = states['which-key']
  return {
    ['which-key'] = {
      enabled = enabled('which-key'), active = state.active == true,
      reason = state.setup_external and 'external_override' or state.reason or 'not_initialized',
      seam = 'replace.desc', setup_seam = 'setup', domain = 'which-key',
      supported_commit = '3aab2147e74890957785941f0c1ad87d0a44c15a',
    },
    telescope = {
      enabled = enabled('telescope'), active = states.telescope.active == true,
      reason = states.telescope.reason or 'not_initialized', seam = 'pickers.new', previewer_seam = 'Previewer:title',
      domain = 'telescope', dynamic_active = states.telescope.title_active == true,
      dynamic_reason = states.telescope.title_reason or 'not_initialized',
      supported_commit = '40aedd8a68c78a656a10a8d62d80c54af59420fb',
    },
    ['lazy.nvim'] = {
      enabled = config.auto and config.lazy_load, active = config.auto and config.lazy_load,
      reason = config.lazy_load and 'shared_notify_and_lazy_load' or 'disabled',
      seam = 'vim.notify; User LazyLoad', domain = 'nvim-ui',
      supported_commit = '306a05526ada86a7b30af95c5cc81ffba93fef97',
    },
    ['nvim-tree'] = {
      enabled = enabled('nvim-tree'), active = states['nvim-tree'].active == true,
      reason = states['nvim-tree'].reason or 'not_initialized', seam = 'setup.on_attach',
      domain = 'nvim-tree', supported_commit = '69eb0c34ed3d836d5a0d92d913b77dd73b054f2f',
    },
    ['nvim-cmp'] = {
      enabled = false, active = false, reason = 'inventory_only_no_cmp_owned_fixed_labels',
      seam = 'none', domain = 'nvim-cmp',
      supported_commit = '2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3',
    },
  }
end

return M
