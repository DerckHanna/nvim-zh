local M = {}
local tracked = {}
local group
local levels = { e = 'error', w = 'warning', n = 'note', i = 'info', f = 'error', r = 'remark' }

function M.get(win, what)
  if win then return vim.fn.getloclist(win, what) end
  return vim.fn.getqflist(what)
end

local function set(win, id, formatter)
  local options = { id = id, quickfixtextfunc = formatter }
  if win then return vim.fn.setloclist(win, {}, 'a', options) end
  return vim.fn.setqflist({}, 'a', options)
end

function M.owner(win)
  if not win or win == 0 then return win end
  local info = vim.fn.getwininfo(win)[1]
  if not info or info.loclist ~= 1 then return win end
  local filewin = vim.fn.getloclist(win, { filewinid = 0 }).filewinid
  return filewin and filewin > 0 and filewin or win
end

local function lookup(win, id)
  local stack = tracked[win or 0]
  return stack and stack[id]
end

local function query(win, id)
  return M.get(win, { id = id, changedtick = 1, quickfixtextfunc = 1 })
end

local function owns(state, list)
  return list.id == state.id and rawequal(list.quickfixtextfunc, state.formatter)
end

local function format(item, text)
  local name = item.module ~= '' and item.module or (item.bufnr ~= 0 and vim.fn.bufname(item.bufnr) or '')
  local location = item.lnum > 0 and tostring(item.lnum) or ''
  if item.end_lnum > 0 and item.end_lnum ~= item.lnum then location = location .. '-' .. item.end_lnum end
  if item.col > 0 then location = location .. ' col ' .. item.col end
  if item.end_col > 0 and item.end_col ~= item.col then location = location .. '-' .. item.end_col end
  if item.lnum > 0 and item.type ~= '' then location = location .. ' ' .. (levels[item.type:lower()] or item.type) end
  if item.nr > 0 then location = location .. (' %3d'):format(item.nr) end
  return name .. '|' .. location .. '| ' .. text:gsub('\n', ' ')
end

local function viable(win)
  return not win or vim.api.nvim_win_is_valid(win)
end

function M.available(win, list, kind)
  if not viable(win) or list.id == 0 or vim.o.quickfixtextfunc ~= '' then return false end
  if list.quickfixtextfunc == '' then return true end
  local state = lookup(win, list.id)
  return state and state.kind == kind and owns(state, list)
end

local function redraw(win, id)
  if not viable(win) then return end
  local current = M.get(win, { id = 0, winid = 1 })
  if current.id ~= id or current.winid == 0 or not vim.api.nvim_win_is_valid(current.winid) then return end
  vim.api.nvim_win_call(current.winid, function()
    local view = vim.fn.winsaveview()
    vim.cmd(win and 'silent noautocmd lopen' or 'silent noautocmd copen')
    vim.fn.winrestview(view)
  end)
end

local function drop(state)
  state.items, state.project, state.revision = nil, nil, nil
  state.records, state.lines = nil, nil
end

local function forget_empty_stacks()
  for key, stack in pairs(tracked) do
    if not next(stack) then tracked[key] = nil end
  end
  if group and not next(tracked) then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

local function sweep(win)
  local stack = tracked[win or 0]
  for id, state in pairs(stack or {}) do
    local list = viable(win) and query(win, id)
    if not list or not owns(state, list) then
      drop(state)
      stack[id] = nil
    end
  end
end

function M.install(win, list, kind, project, revision)
  if not viable(win) then return end
  local current = query(win, list.id)
  if current.id ~= list.id or current.changedtick ~= list.changedtick or not M.available(win, current, kind) then return end
  if not group then
    group = vim.api.nvim_create_augroup('NvimZhListDisplay', { clear = true })
    vim.api.nvim_create_autocmd('OptionSet', { group = group, pattern = 'quickfixtextfunc', callback = function()
      if vim.o.quickfixtextfunc ~= '' then M.clear() end
    end })
    vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(event)
      local handle = tonumber(event.match)
      local stack = tracked[handle]
      for _, state in pairs(stack or {}) do drop(state) end
      if handle then tracked[handle] = nil end
      forget_empty_stacks()
    end })
  end
  local state = { id = list.id, win = win, kind = kind, items = list.items, project = project, revision = revision }
  local function prepare()
    local version = state.revision and state.revision()
    if version == nil then return end
    if version ~= state.version then
      state.records = state.project(state.items)
      local lines = {}
      for i, record in pairs(state.records) do
        if record.text ~= state.items[i].text then lines[i] = format(state.items[i], record.text) end
      end
      state.lines, state.version = lines, version
    end
    return state.records
  end
  state.prepare = prepare
  state.formatter = function(info)
    if lookup(win, state.id) ~= state or info.id ~= state.id
      or (info.quickfix == 0) ~= (win ~= nil) or (win and M.owner(info.winid) ~= win)
      or vim.o.quickfixtextfunc ~= '' or not viable(win) then return {} end
    local now = query(win, state.id)
    if now.changedtick ~= state.tick or not owns(state, now) or not prepare() then return {} end
    local lines = {}
    for i = info.start_idx, info.end_idx do lines[#lines + 1] = state.lines[i] or '' end
    return lines
  end
  if set(win, state.id, state.formatter) ~= 0 then forget_empty_stacks(); return end
  local installed = query(win, state.id)
  if not owns(state, installed) then forget_empty_stacks(); return end
  state.tick = installed.changedtick
  sweep(win)
  local key = win or 0
  tracked[key] = tracked[key] or {}
  tracked[key][state.id] = state
  redraw(win, state.id)
  return prepare()
end

function M.refresh(kind)
  for key, stack in pairs(tracked) do
    sweep(key ~= 0 and key or nil)
    for _, state in pairs(stack) do
      if kind == nil or kind == state.kind then redraw(state.win, state.id) end
    end
  end
  forget_empty_stacks()
end

function M.clear(kind)
  for _, stack in pairs(tracked) do
    for id, state in pairs(stack) do
      if kind == nil or kind == state.kind then
        drop(state)
        stack[id] = nil
        if viable(state.win) and owns(state, query(state.win, id)) then
          set(state.win, id, '')
          redraw(state.win, id)
        end
      end
    end
  end
  forget_empty_stacks()
end

function M.raw()
  local current = vim.api.nvim_get_current_win()
  local win = vim.fn.getwininfo(current)[1].loclist == 1 and M.owner(current) or nil
  local list = M.get(win, { id = 0, idx = 0, items = 1, changedtick = 1, quickfixtextfunc = 1 })
  local item = list.items and list.items[list.idx]
  if not item then return end
  local state = lookup(win, list.id)
  local records = state and state.tick == list.changedtick and owns(state, list) and state.prepare()
  local record = records and records[list.idx]
  return vim.tbl_extend('force', record or {}, { raw_text = item.text, item = item, index = list.idx })
end

return M
