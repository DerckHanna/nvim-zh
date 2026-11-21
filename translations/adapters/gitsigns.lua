local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'gitsigns'
local AUGROUP = 'NvimZhGitsignsAdapter'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  release_source = nil,
  source_error = nil,
  popup_generation = nil,
  popup_records = {},
  msg_generation = nil,
  msg_records = {},
  actions_generation = nil,
  actions_records = {},
  nav_generation = nil,
  nav_records = {},
}

local ACTION_METHODS = {
  'stage_hunk',
  'reset_hunk',
  'reset_buffer',
  'undo_stage_hunk',
  'stage_buffer',
  'nav_hunk',
  'next_hunk',
  'prev_hunk',
  'preview_hunk',
  'blame_line',
}

local function translate(context, text)
  if type(state.ctx) ~= 'table' or type(text) ~= 'string' or text == '' then return text end
  return state.ctx.translate(DOMAIN, context, text)
end

local function verify(surface)
  local ctx = state.ctx
  if type(ctx) ~= 'table' then return nil, 'not_loaded' end
  if type(ctx.verify) ~= 'function' then return { kind = 'offline' }, nil end
  return ctx.verify(surface)
end

local function popups_enabled(generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and state.popup_generation ~= nil and rawequal(state.popup_generation, generation)
    and rawequal(package.loaded['gitsigns.popup'], generation)
    and verify('popups') ~= nil
end

local function messages_enabled(generation, module_name)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and rawequal(package.loaded[module_name], generation)
    and verify('messages') ~= nil
end

local function translate_popup_chunk(text)
  if type(text) ~= 'string' or text == '' then return text end
  local prefix, desc = text:match('^(%S+%s+)(.+)$')
  if prefix and desc and #prefix == 9 then
    local translated_desc = translate('popup', desc)
    if translated_desc ~= desc then
      return prefix .. translated_desc
    end
  end
  return translate('popup', text)
end

local function project_lines_spec(lines_spec)
  if type(lines_spec) ~= 'table' then return lines_spec end
  local projected = {}
  for i, section in ipairs(lines_spec) do
    if type(section) == 'table' then
      local new_section = {}
      for j, part in ipairs(section) do
        if type(part) == 'table' and type(part[1]) == 'string' and type(part[2]) == 'string' then
          local new_part = common.copy(part)
          new_part[1] = translate_popup_chunk(part[1])
          new_section[j] = new_part
        else
          new_section[j] = part
        end
      end
      projected[i] = new_section
    else
      projected[i] = section
    end
  end
  return projected
end

local function with_scoped_echo(fn, ...)
  local prev_echo = vim.api.nvim_echo
  local prev_print = _G.print

  local echo_proxy = function(chunks, history, opts)
    if type(chunks) == 'table' and type(chunks[1]) == 'table' and type(chunks[1][1]) == 'string' then
      local copy_chunks = common.copy(chunks)
      local first = common.copy(chunks[1])
      first[1] = translate('echo', first[1])
      copy_chunks[1] = first
      chunks = copy_chunks
    end
    return prev_echo(chunks, history, opts)
  end

  local print_proxy = function(first, ...)
    if select('#', ...) == 0 and type(first) == 'string' then
      return prev_print(translate('echo', first))
    end
    return prev_print(first, ...)
  end

  vim.api.nvim_echo = echo_proxy
  _G.print = print_proxy
  local results = common.pack(pcall(fn, ...))
  if vim.api.nvim_echo == echo_proxy then vim.api.nvim_echo = prev_echo end
  if _G.print == print_proxy then _G.print = prev_print end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local function sync_popup()
  local current = package.loaded['gitsigns.popup']
  if current ~= state.popup_generation then
    if state.popup_generation ~= nil then
      common.unwrap(state.popup_records, 'create')
      common.unwrap(state.popup_records, 'update')
    end
    state.popup_records = {}
    state.popup_generation = current
  end
  if type(current) ~= 'table' then return end
  if type(current.create) == 'function' then
    common.wrap(state.popup_records, 'create', function()
      return current.create
    end, function(value)
      current.create = value
    end, function(original)
      return function(lines_spec, opts, id, ...)
        if popups_enabled(current) and common.active(state.popup_records, 'create') then
          lines_spec = project_lines_spec(lines_spec)
        end
        return original(lines_spec, opts, id, ...)
      end
    end)
  end
  if type(current.update) == 'function' then
    common.wrap(state.popup_records, 'update', function()
      return current.update
    end, function(value)
      current.update = value
    end, function(original)
      return function(winid, bufnr, lines_spec, opts, ...)
        if popups_enabled(current) and common.active(state.popup_records, 'update') then
          lines_spec = project_lines_spec(lines_spec)
        end
        return original(winid, bufnr, lines_spec, opts, ...)
      end
    end)
  end
end

local function sync_message()
  local current = package.loaded['gitsigns.message']
  if current ~= state.msg_generation then
    if state.msg_generation ~= nil then
      for _, method in ipairs({ 'warn', 'error', 'error_once' }) do
        common.unwrap(state.msg_records, method)
      end
    end
    state.msg_records = {}
    state.msg_generation = current
  end
  if type(current) ~= 'table' then return end
  for _, method in ipairs({ 'warn', 'error', 'error_once' }) do
    if type(current[method]) == 'function' then
      common.wrap(state.msg_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(fmt, ...)
          if messages_enabled(current, 'gitsigns.message')
              and common.active(state.msg_records, method) and type(fmt) == 'string' then
            local formatted = fmt
            if select('#', ...) > 0 then
              local ok, res = pcall(string.format, fmt, ...)
              if not ok then return original(fmt, ...) end
              formatted = res
            end
            local translated = translate('notification', formatted)
            return original((translated:gsub('%%', '%%%%')))
          end
          return original(fmt, ...)
        end
      end)
    end
  end
end

local sync_all

local function sync_actions()
  local current = package.loaded['gitsigns.actions']
  if current ~= state.actions_generation then
    if state.actions_generation ~= nil then
      for _, method in ipairs(ACTION_METHODS) do
        common.unwrap(state.actions_records, method)
      end
    end
    state.actions_records = {}
    state.actions_generation = current
  end
  if type(current) ~= 'table' then return end
  for _, method in ipairs(ACTION_METHODS) do
    if type(current[method]) == 'function' then
      common.wrap(state.actions_records, method, function()
        return current[method]
      end, function(value)
        current[method] = value
      end, function(original)
        return function(...)
          if not messages_enabled(current, 'gitsigns.actions')
              or not common.active(state.actions_records, method) then
            return original(...)
          end
          if method == 'preview_hunk' or method == 'blame_line' then
            pcall(require, 'gitsigns.popup')
            sync_popup()
          elseif method == 'nav_hunk' or method == 'next_hunk' or method == 'prev_hunk' then
            pcall(require, 'gitsigns.actions.nav')
            sync_all()
          end
          return with_scoped_echo(original, ...)
        end
      end)
    end
  end
end

local function sync_nav()
  local current = package.loaded['gitsigns.actions.nav']
  if current ~= state.nav_generation then
    if state.nav_generation ~= nil then
      common.unwrap(state.nav_records, 'nav_hunk')
    end
    state.nav_records = {}
    state.nav_generation = current
  end
  if type(current) ~= 'table' or type(current.nav_hunk) ~= 'function' then return end
  common.wrap(state.nav_records, 'nav_hunk', function()
    return current.nav_hunk
  end, function(value)
    current.nav_hunk = value
  end, function(original)
    return function(...)
      if not messages_enabled(current, 'gitsigns.actions.nav')
          or not common.active(state.nav_records, 'nav_hunk') then
        return original(...)
      end
      return with_scoped_echo(original, ...)
    end
  end)
end

sync_all = function()
  if type(package.loaded['gitsigns']) == 'table' and package.loaded['gitsigns.popup'] == nil then
    pcall(require, 'gitsigns.popup')
  end
  sync_popup()
  sync_message()
  sync_actions()
  sync_nav()
end

local function ensure_source(ctx)
  if state.release_source or type(ctx.register_source) ~= 'function' then return end
  local ok, release = pcall(ctx.register_source, {
    title = 'gitsigns',
    domain = DOMAIN,
    context = 'notification',
  })
  if ok then
    state.release_source = release
    state.source_error = nil
  else
    state.source_error = tostring(release)
  end
end

local function release_source()
  if state.release_source then
    pcall(state.release_source)
    state.release_source = nil
  end
end

local function setup_autocmd()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  if not state.enabled then return end
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitSignsUpdate',
    desc = 'nvim-zh: sync gitsigns submodules on update',
    callback = function()
      if state.enabled then sync_all() end
    end,
  })
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  ensure_source(ctx)
  setup_autocmd()
  sync_all()
end

function M.detach()
  state.enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  release_source()
  common.unwrap(state.popup_records, 'create')
  common.unwrap(state.popup_records, 'update')
  state.popup_records = {}
  state.popup_generation = nil
  for _, method in ipairs({ 'warn', 'error', 'error_once' }) do
    common.unwrap(state.msg_records, method)
  end
  state.msg_records = {}
  state.msg_generation = nil
  for _, method in ipairs(ACTION_METHODS) do
    common.unwrap(state.actions_records, method)
  end
  state.actions_records = {}
  state.actions_generation = nil
  common.unwrap(state.nav_records, 'nav_hunk')
  state.nav_records = {}
  state.nav_generation = nil
end

function M.signature()
  local popup = package.loaded['gitsigns.popup']
  local msg = package.loaded['gitsigns.message']
  local actions = package.loaded['gitsigns.actions']
  local nav = package.loaded['gitsigns.actions.nav']
  return table.concat({
    tostring(package.loaded['gitsigns']),
    tostring(popup),
    type(popup) == 'table' and tostring(popup.create) or '',
    tostring(msg),
    type(msg) == 'table' and tostring(msg.error) or '',
    tostring(actions),
    type(actions) == 'table' and tostring(actions.stage_hunk) or '',
    tostring(nav),
    type(nav) == 'table' and tostring(nav.nav_hunk) or '',
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local popups_verified, popups_why = verify('popups')
  local msg_verified, msg_why = verify('messages')

  local popups_active = enabled and popups_verified ~= nil and (
    common.active(state.popup_records, 'create')
    or common.active(state.popup_records, 'update')
  )
  local msg_active = enabled and msg_verified ~= nil and (
    common.active(state.msg_records, 'error')
    or common.active(state.actions_records, 'stage_hunk')
    or common.active(state.nav_records, 'nav_hunk')
  )

  local reason
  if not enabled then
    reason = 'disabled'
  elseif common.reason(state.popup_records, 'create') == 'external_override'
      or common.reason(state.msg_records, 'error') == 'external_override' then
    reason = 'external_override'
  elseif popups_active or msg_active then
    reason = nil
  elseif package.loaded['gitsigns.popup'] == nil and package.loaded['gitsigns.message'] == nil
      and package.loaded['gitsigns.actions'] == nil then
    reason = 'not_loaded'
  else
    reason = popups_why or msg_why or common.reason(state.msg_records, 'error')
  end

  return {
    active = popups_active or msg_active,
    reason = reason,
    seam = 'vim.notify:title=gitsigns; gitsigns.message.{warn,error,error_once}; gitsigns.popup.{create,update}; gitsigns.actions.{stage_hunk,reset_hunk,reset_buffer,undo_stage_hunk,stage_buffer,nav_hunk}',
    domain = DOMAIN,
    popups = {
      active = popups_active,
      reason = popups_verified and common.reason(state.popup_records, 'create') or popups_why,
    },
    messages = {
      active = msg_active,
      reason = msg_verified and common.reason(state.msg_records, 'error') or msg_why,
      error = state.source_error,
    },
  }
end

return M
