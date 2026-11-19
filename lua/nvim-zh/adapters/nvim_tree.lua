local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'nvim-tree'
local PREFIX = 'nvim-tree: '
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
  ctx = nil,
}

-- Display-path seams. Each slot owns one upstream module function; the wrapper
-- is installed when the leaf module is loaded and stays inert until the pinned
-- source digests verify, so an unknown revision keeps rendering upstream text.
local slots = {
  prompt = {
    module = 'nvim-tree.lib',
    method = 'prompt',
    surface = 'prompts',
    records = {},
    generation = nil,
  },
  help = {
    module = 'nvim-tree.help',
    method = 'toggle',
    surface = 'help_buffer',
    records = {},
    generation = nil,
  },
  window_picker = {
    module = 'nvim-tree.actions.node.open-file',
    method = 'fn',
    surface = 'window_picker',
    records = {},
    generation = nil,
  },
  file_popup = {
    module = 'nvim-tree.actions.node.file-popup',
    method = 'toggle_file_info',
    surface = 'file_info',
    records = {},
    generation = nil,
  },
  hidden_count = {
    module = 'nvim-tree.renderer.builder',
    method = 'setup_hidden_display_function',
    surface = 'renderer_hidden',
    records = {},
    generation = nil,
  },
}

local attach_keymap
local attach_display

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
        local display_ok, display_err = pcall(attach_display)
        if not display_ok then state.load_error = tostring(display_err) end
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
      if not state.enabled or state.keymap ~= keymap or keymap.on_attach_default ~= wrapper
        or not rawequal(package.loaded['nvim-tree.keymap'], keymap) then
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

-- ---------------------------------------------------------------------------
-- Display seams
-- ---------------------------------------------------------------------------

local function translate(context, text)
  if type(state.ctx) ~= 'table' or type(text) ~= 'string' then return text end
  return state.ctx.translate(DOMAIN, context, text)
end

local function verify(surface)
  local ctx = state.ctx
  if type(ctx) ~= 'table' or type(ctx.verify) ~= 'function' then
    return nil, 'unsupported_api'
  end
  return ctx.verify(surface)
end

local function display_enabled(slot, generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.ctx and slot.generation ~= nil and rawequal(slot.generation, generation)
    and rawequal(package.loaded[slot.module], generation)
    and common.active(slot.records, slot.method)
    and verify(slot.surface) ~= nil
end

local function sync_slot(slot)
  local current = package.loaded[slot.module]
  if current ~= slot.generation then
    if slot.generation ~= nil then common.unwrap(slot.records, slot.method) end
    slot.records = {}
    slot.generation = current
  end
  if type(current) ~= 'table' or type(current[slot.method]) ~= 'function' then return end

  local factory = slot.factory
  common.wrap(slot.records, slot.method, function()
    return current[slot.method]
  end, function(value)
    current[slot.method] = value
  end, function(original)
    return factory(original, current)
  end)
end

-- Item 1: prompt/select and items_long.
--
-- lib.lua:73-95 `M.prompt(prompt_input, prompt_select, items_short, items_long,
-- kind, callback)` is the single dispatcher for all eight nvim-tree confirmation
-- call sites (clipboard.lua:264/285, remove-file.lua:153/193, trash.lua:104/136,
-- marks/init.lua:204/233). Every one of those files holds its own
-- `local lib = require("nvim-tree.lib")`, so they share the one module table and
-- a field patch on that table is what they call. Only DISPLAY arguments are
-- projected: prompt_select, prompt_input and items_long. `items_short` is the
-- protocol ({"", "y", "n"} / {"", "y"} / {"", "n"}) and stays byte-identical, and
-- the callback is forwarded untouched, so the `item_short` value the plugin
-- branches on ("y" / "n" / "" / "r") is exactly the upstream value.
--
-- vim.ui.select/input are asynchronous, so no global vim.ui proxy is installed;
-- the projection happens on the arguments at the owned call and is complete
-- before the plugin hands control to the UI layer.
local KINDS = {
  nvimtree_remove = true,
  nvimtree_trash = true,
  nvimtree_bulk_delete = true,
  nvimtree_bulk_trash = true,
  nvimtree_overwrite_rename = true,
  nvimtree_paste_conflict = true,
}

local function project_items_long(items_long, generation)
  if type(items_long) ~= 'table' then return items_long end
  local projected, changed = {}, false
  for index, label in ipairs(items_long) do
    local translated = label
    if display_enabled(slots.prompt, generation) and type(label) == 'string' then
      translated = translate('select_item', label)
    end
    projected[index] = translated
    if translated ~= label then changed = true end
  end
  return changed and projected or items_long
end

slots.prompt.factory = function(original, generation)
  return function(prompt_input, prompt_select, items_short, items_long, kind, callback)
    if not display_enabled(slots.prompt, generation) or not KINDS[kind] then
      return original(prompt_input, prompt_select, items_short, items_long, kind, callback)
    end
    -- Count prompts use their own context so a "%s" node template can never
    -- absorb a "%d selected" prompt.
    local function project(text)
      if type(text) ~= 'string' then return text end
      local value = translate('prompt', text)
      if value ~= text then return value end
      return translate('prompt_count', text)
    end
    local projected_select = project(prompt_select)
    local projected_input = project(prompt_input)
    local projected_long = project_items_long(items_long, generation)
    -- items_short and callback are forwarded unchanged.
    return original(projected_input, projected_select, items_short, projected_long, kind, callback)
  end
end

-- Item 5: file info popup.
--
-- file-popup.lua:36-59 builds lines with fixed label prefixes and pads the value
-- onto them; :39-44 sizes the window from `#lines` BEFORE the buffer exists, and
-- :47/:50 create the popup window/buffer. The wrapper records the exact
-- bufnr/winnr this one call created by scoping nvim_open_win and
-- nvim_buf_set_lines around the original, then rewrites only those two objects,
-- so the seam is provenance-based rather than a buffer scan. Width is recomputed
-- with strdisplaywidth because CJK labels are double-width in the terminal.
local LABEL_PREFIXES = { ' fullpath: ', ' created:  ', ' modified: ', ' accessed: ', ' size:     ' }
local NOT_RETRIEVABLE = "  Can't retrieve file information"

local function project_popup_line(line)
  for _, prefix in ipairs(LABEL_PREFIXES) do
    if line:sub(1, #prefix) == prefix then
      local translated = translate('popup', prefix)
      if translated == prefix then return line end
      return translated .. line:sub(#prefix + 1)
    end
  end
  if line == NOT_RETRIEVABLE then
    local translated = translate('popup', NOT_RETRIEVABLE)
    if translated ~= NOT_RETRIEVABLE then return translated end
  end
  return line
end

local function display_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    local columns = vim.fn.strdisplaywidth(line)
    if columns > width then width = columns end
  end
  return width
end

slots.file_popup.factory = function(original, generation)
  return function(node, ...)
    if not display_enabled(slots.file_popup, generation) then
      return original(node, ...)
    end

    local created = { bufnr = nil, winnr = nil, config = nil }
    local original_open = vim.api.nvim_open_win
    local original_set_lines = vim.api.nvim_buf_set_lines
    local open_win
    local set_lines

    open_win = function(buf, enter, config, ...)
      local winnr = original_open(buf, enter, config, ...)
      if created.winnr == nil then
        created.winnr, created.config = winnr, config
      end
      return winnr
    end
    set_lines = function(buf, start, finish, strict, lines, ...)
      if created.bufnr == nil then created.bufnr = buf end
      return original_set_lines(buf, start, finish, strict, lines, ...)
    end

    vim.api.nvim_open_win = open_win
    vim.api.nvim_buf_set_lines = set_lines
    local results = common.pack(pcall(original, node, ...))
    if vim.api.nvim_open_win == open_win then vim.api.nvim_open_win = original_open end
    if vim.api.nvim_buf_set_lines == set_lines then vim.api.nvim_buf_set_lines = original_set_lines end
    if not results[1] then error(results[2], 0) end

    -- Only the objects this call created are touched. A toggle-off call or a
    -- call for another node left them nil and is skipped.
    if created.bufnr and created.winnr and vim.api.nvim_buf_is_valid(created.bufnr)
      and vim.api.nvim_win_is_valid(created.winnr) then
      local ok_lines, current = pcall(vim.api.nvim_buf_get_lines, created.bufnr, 0, -1, false)
      if ok_lines and type(current) == 'table' and #current > 0 then
        local projected, changed = {}, false
        for index, line in ipairs(current) do
          projected[index] = project_popup_line(line)
          if projected[index] ~= line then changed = true end
        end
        if changed then
          -- `size:     ` padding is part of the upstream literal and is kept by
          -- the catalog entry, so the projected lines keep their alignment.
          pcall(vim.api.nvim_buf_set_lines, created.bufnr, 0, -1, false, projected)
          if created.config then
            local width = display_width(projected) + 1
            if width ~= created.config.width then
              local config = common.copy(created.config)
              config.width = width
              pcall(vim.api.nvim_win_set_config, created.winnr, config)
            end
          end
        end
      end
    end

    return unpack(results, 2, results.n)
  end
end


-- Declared as a forward local because slots.help.factory below installs it and
-- the help keymap callbacks re-enter it recursively.
local with_help_interception

slots.help.factory = function(original, generation)
  return function(...)
    return with_help_interception(generation, original, ...)
  end
end

-- Item 3: help buffer headers and help-local keymap descriptions.
--
-- help.lua:191-268 `open()` is a local function reached only through `M.toggle`
-- (:270), the public `api.tree.toggle_help` (api/impl.lua:274). `compute()`
-- (:89-176) builds the two header lines and the highlight ranges from
-- `#head_lhs`/`width`; `open()` sizes the window from `width` and `#lines`.
--
-- Match the populate call for this Help Buffer and its Window. The mapping
-- rows already use translated default keymap descriptions. Project the two
-- headers and Help-specific mapping descriptions here, using display columns
-- for padding and Window width and byte offsets for highlights.
local HEAD_LHS = 'nvim-tree mappings'
local HEAD_RHS1 = 'exit: q'
local HEAD_RHS2 = 'sort by %s: s'

local function help_highlight_ranges(lines, head_lhs)
  return {
    { higroup = 'NvimTreeFolderName', start = { 0, 0 }, finish = { 0, #head_lhs } },
    { higroup = 'NvimTreeFolderName', start = { 0, #lines[1] - 1 }, finish = { 0, #lines[1] } },
    { higroup = 'NvimTreeFolderName', start = { 1, #lines[2] - 1 }, finish = { 1, #lines[2] } },
  }
end

-- `s` inside the help buffer calls toggle_sort -> the local open(), i.e. a
-- second populate that never passes through M.toggle. The help keymaps are
-- (re)registered at the end of every open() call, so a scoped vim.keymap.set
-- proxy wraps exactly those callbacks and makes each invocation re-enter the
-- same projection below.
with_help_interception = function(generation, fn, ...)
  if not display_enabled(slots.help, generation) then return fn(...) end
  do

    local created = { bufnr = nil, winnr = nil, config = nil }
    local original_open = vim.api.nvim_open_win
    local original_set_lines = vim.api.nvim_buf_set_lines
    local original_keymap_set = vim.keymap.set
    local open_win
    local set_lines
    local keymap_set

    open_win = function(buf, enter, config, ...)
      local winnr = original_open(buf, enter, config, ...)
      if buf == created.bufnr then created.winnr, created.config = winnr, config end
      return winnr
    end
    set_lines = function(buf, start, finish, strict, lines, ...)
      if created.bufnr == nil and start == 0 and finish == -1 and type(lines) == 'table'
          and type(lines[1]) == 'string' and vim.startswith(lines[1], HEAD_LHS) then
        created.bufnr = buf
      end
      return original_set_lines(buf, start, finish, strict, lines, ...)
    end

    -- Wrap only callbacks this open() registers on the help buffer, so `s`
    -- (toggle_sort -> local open()) re-enters the projection instead of
    -- repainting the English header outside the seam.
    keymap_set = function(mode, lhs, rhs, opts)
      if created.bufnr and type(opts) == 'table' and opts.buffer == created.bufnr then
        local copy = common.copy(opts)
        copy.desc = translate('help_buffer', opts.desc)
        if lhs == 's' and type(rhs) == 'function' then
          local sort = rhs
          rhs = function(...) return with_help_interception(generation, sort, ...) end
        end
        opts = copy
      end
      return original_keymap_set(mode, lhs, rhs, opts)
    end

    vim.api.nvim_open_win = open_win
    vim.api.nvim_buf_set_lines = set_lines
    vim.keymap.set = keymap_set
    local results = common.pack(pcall(fn, ...))
    if vim.api.nvim_open_win == open_win then vim.api.nvim_open_win = original_open end
    if vim.api.nvim_buf_set_lines == set_lines then vim.api.nvim_buf_set_lines = original_set_lines end
    if vim.keymap.set == keymap_set then vim.keymap.set = original_keymap_set end
    if not results[1] then error(results[2], 0) end

    -- Only the buffer and window this toggle created. A toggle-off call leaves
    -- them nil and is skipped.
    if created.bufnr and created.winnr and vim.api.nvim_buf_is_valid(created.bufnr)
      and vim.api.nvim_win_is_valid(created.winnr) then
      local ok_lines, current = pcall(vim.api.nvim_buf_get_lines, created.bufnr, 0, -1, false)
      if ok_lines and type(current) == 'table' and #current > 2 then
        local head_lhs = translate('help_buffer', HEAD_LHS)
        local head_rhs1 = translate('help_buffer', HEAD_RHS1)

        -- head_rhs2 names the sort method the `s` key switches TO, so the
        -- upstream second line always contains exactly one of the two English
        -- method names. Read it back instead of re-deriving the config, so the
        -- projected line stays correct after an `s` re-render.
        local original_second = current[2]
        local next_sort
        if type(original_second) == 'string' then
          if original_second:find('description', 1, true) then next_sort = 'description'
          elseif original_second:find('keymap', 1, true) then next_sort = 'keymap' end
        end
        if not next_sort then return unpack(results, 2, results.n) end
        local head_rhs2 = string.format(translate('help_buffer', HEAD_RHS2), translate('help_buffer', next_sort))

        local original_first = current[1]
        if vim.startswith(original_first, HEAD_LHS) and original_first:sub(#HEAD_LHS + 1):match('^%s+exit: q$') then
          -- Align the q and s keys by display column.
          local width = vim.fn.strdisplaywidth(original_first)
          for _, line in ipairs(current) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
          local left = vim.fn.strdisplaywidth(head_lhs)
          local exit, sort = vim.fn.strdisplaywidth(head_rhs1), vim.fn.strdisplaywidth(head_rhs2)
          width = math.max(width, left + 3 + exit, sort + 3)
          local first = head_lhs .. string.rep(' ', width - left - exit) .. head_rhs1
          local second = string.rep(' ', width - sort) .. head_rhs2
          if first ~= current[1] or second ~= current[2] then
            pcall(vim.api.nvim_set_option_value, 'modifiable', true, { buf = created.bufnr })
            pcall(vim.api.nvim_buf_set_lines, created.bufnr, 0, 2, false, { first, second })
            pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = created.bufnr })
          end

          -- Redraw the same three header highlight ranges upstream drew, with
          -- the byte offsets recomputed for the projected width.
          local namespace = vim.api.nvim_create_namespace('NvimTreeHelp')
          pcall(vim.api.nvim_buf_clear_namespace, created.bufnr, namespace, 0, 2)
          for _, args in ipairs(help_highlight_ranges({ first, second }, head_lhs)) do
            pcall(vim.hl.range, created.bufnr, namespace, args.higroup, args.start, args.finish, {})
          end

          -- Upstream sizes the window from `#lines[1]` and then widens it to
          -- the longest mapping row, so the projected width must be the max
          -- over every row rather than the header alone.
          if created.config and created.config.width ~= width then
            local config = common.copy(created.config)
            config.width = width
            pcall(vim.api.nvim_win_set_config, created.winnr, config)
          end
        end
      end
    end

    return unpack(results, 2, results.n)
  end
end

-- Item 4: `print("Pick window: ")`.
--
-- open-file.lua:139 prints a bare literal inside pick_win_id, which is reached
-- from get_target_winid (:245) inside open_in_new_window (:275) inside the
-- module entry M.fn (:370). M.fn is the public entry behind every
-- api.node.open.* action (api/impl.lua:234-249). The surrounding function is
-- synchronous: it calls vim.cmd("redraw") then print then pcall(get_user_input_char),
-- and get_user_input_char loops vim.fn.getchar, which blocks but never yields a
-- coroutine. A scoped _G.print replacement for the duration of the call is
-- therefore safe and is restored on every path.
local PICK_WINDOW = 'Pick window: '

slots.window_picker.factory = function(original, generation)
  return function(...)
    if not display_enabled(slots.window_picker, generation) then return original(...) end
    local original_print = _G.print
    if type(original_print) ~= 'function' then return original(...) end
    local translated_print
    translated_print = function(...)
      local args = common.pack(...)
      if args.n > 0 and args[1] == PICK_WINDOW then
        if display_enabled(slots.window_picker, generation) then
          args[1] = translate('window_picker', PICK_WINDOW)
        end
      end
      return original_print(unpack(args, 1, args.n))
    end
    _G.print = translated_print
    local results = common.pack(pcall(original, ...))
    if _G.print == translated_print then _G.print = original_print end
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
  end
end

-- The built-in modes share utils.default_format_hidden_count. Project their
-- fixed labels and keep the counts and filter keys used by the renderer.
slots.hidden_count.factory = function(original, generation)
  -- Builder:setup_hidden_display_function is a colon method, so the first
  -- argument is the Builder instance and opts is the second.
  return function(self, opts, ...)
    if type(opts) ~= 'table' or type(opts.renderer) ~= 'table' then
      return original(self, opts, ...)
    end
    local returned = original(self, opts, ...)
    if type(returned) ~= 'function' then return returned end
    local hidden_display = opts.renderer.hidden_display
    -- A user function is configuration data, not a plugin-built skeleton.
    if type(hidden_display) ~= 'string' or hidden_display == 'none' then return returned end
    return function(...)
      local value = returned(...)
      if type(value) ~= 'string' or value == '' then return value end
      if not display_enabled(slots.hidden_count, generation) then return value end
      local reason_labels = value:gsub('([%a_]+): (%d+)', function(reason, count)
        local name = reason:gsub('_', ' ')
        local label = translate('hidden_reason', name)
        return label == name and reason .. ': ' .. count or label .. '：' .. count
      end)
      return translate('tree_window', reason_labels)
    end
  end
end

local SLOT_ORDER = { 'prompt', 'help', 'window_picker', 'file_popup', 'hidden_count' }

local function sync_display()
  for _, name in ipairs(SLOT_ORDER) do
    local slot = slots[name]
    -- Never force the plugin to load: only leaf modules that are already
    -- loaded are adopted. nvim-tree.lib is loaded by every action, while help,
    -- open-file, file-popup and renderer.builder are loaded on demand by their
    -- own public entry, so they are picked up by the VimEnter/BufEnter sweep
    -- once the plugin itself has touched them.
    if package.loaded[slot.module] == nil and state.tree ~= nil
      and type(package.loaded['nvim-tree.config']) == 'table'
      and type(package.loaded['nvim-tree.config'].g) == 'table' then
      pcall(require, slot.module)
    end
    if package.loaded[slot.module] ~= nil then sync_slot(slot) end
  end
end

attach_display = function()
  state.load_error = nil
  sync_display()
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
  attach_display()
end

function M.detach()
  state.enabled = false
  state.ctx = nil
  if state.release_source then
    state.release_source()
    state.release_source = nil
  end
  state.source_error = nil
  -- Same-module external replacements stay owned by the caller across a later
  -- re-attach. Only sync_* on an actual module-table generation clears records.
  restore_tree()
  restore_keymap()
  for _, name in ipairs(SLOT_ORDER) do
    local slot = slots[name]
    common.unwrap(slot.records, slot.method, 'disabled')
  end
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

  local function display_info(slot)
    local verified, why = verify(slot.surface)
    return {
      active = enabled and common.active(slot.records, slot.method) and verified ~= nil,
      reason = verified and common.reason(slot.records, slot.method) or why,
      loaded = package.loaded[slot.module] ~= nil,
    }
  end

  return {
    active = active,
    reason = reason,
    seam = 'keymap.on_attach_default; setup lifecycle; exact vim.notify title; '
      .. 'lib.prompt arguments; help toggle; open-file fn; file-popup toggle_file_info; '
      .. 'builder hidden-display closure',
    domain = DOMAIN,
    version_related = 'display seams pinned per leaf module; inert without matching digests',
    setup_active = enabled and common.active(state.tree_records, 'setup'),
    setup_reason = setup_reason,
    keymap_reason = keymap_reason,
    default_mappings = { active = active, reason = reason },
    notification = { active = enabled and state.release_source ~= nil, error = state.source_error },
    notification_source = state.release_source ~= nil,
    notification_error = state.source_error,
    load_error = state.load_error,
    existing_buffers = 'not_reattached',
    prompts = display_info(slots.prompt),
    help_buffer = display_info(slots.help),
    window_picker = display_info(slots.window_picker),
    file_info = display_info(slots.file_popup),
    renderer_hidden = display_info(slots.hidden_count),
  }
end

function M.signature()
  local tree = package.loaded['nvim-tree']
  local keymap = package.loaded['nvim-tree.keymap']
  local values = {
    tostring(tree),
    type(tree) == 'table' and tostring(tree.setup) or '',
    tostring(keymap),
    type(keymap) == 'table' and tostring(keymap.on_attach_default) or '',
  }
  for _, name in ipairs(SLOT_ORDER) do
    local slot = slots[name]
    values[#values + 1] = tostring(package.loaded[slot.module])
  end
  return table.concat(values, ':')
end

return M
