local M = {}
local tracked = {}
local option_hook
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

local function lookup(id)
  local state = tracked[id % 64]
  return state and state.id == id and state or nil
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
  local state = lookup(list.id)
  return state and state.kind == kind and state.win == win and rawequal(list.quickfixtextfunc, state.formatter)
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

function M.install(win, list, kind, project, revision)
  local current = M.get(win, { id = list.id, changedtick = 1, quickfixtextfunc = 1 })
  if current.id ~= list.id or current.changedtick ~= list.changedtick or not M.available(win, current, kind) then return end
  if not option_hook then
    option_hook = vim.api.nvim_create_autocmd('OptionSet', { pattern = 'quickfixtextfunc', callback = function()
      if vim.o.quickfixtextfunc ~= '' then M.clear() end
    end })
  end
  local state = { id = list.id, win = win, kind = kind, items = list.items, project = project, revision = revision }
  local function prepare()
    local version = state.revision()
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
  state.formatter = function(info)
    if info.id ~= state.id or (info.quickfix == 0) ~= (win ~= nil) or vim.o.quickfixtextfunc ~= '' then return {} end
    local now = M.get(win, { id = state.id, changedtick = 1, quickfixtextfunc = 1 })
    if now.changedtick ~= state.tick or not rawequal(now.quickfixtextfunc, state.formatter) or not prepare() then return {} end
    local lines = {}
    for i = info.start_idx, info.end_idx do lines[#lines + 1] = state.lines[i] or '' end
    return lines
  end
  if set(win, state.id, state.formatter) ~= 0 then return end
  local installed = M.get(win, { id = state.id, changedtick = 1, quickfixtextfunc = 1 })
  if not rawequal(installed.quickfixtextfunc, state.formatter) then return end
  state.tick = installed.changedtick
  tracked[state.id % 64] = state
  redraw(win, state.id)
  return prepare()
end

function M.refresh(kind)
  for _, state in pairs(tracked) do
    if (kind == nil or kind == state.kind) and viable(state.win) then
      local list = M.get(state.win, { id = state.id, changedtick = 1, quickfixtextfunc = 1 })
      if list.changedtick == state.tick and rawequal(list.quickfixtextfunc, state.formatter) then
        redraw(state.win, state.id)
      end
    end
  end
end

function M.clear(kind)
  for slot, state in pairs(tracked) do
    if kind == nil or kind == state.kind then
      tracked[slot] = nil
      if viable(state.win) then
        local list = M.get(state.win, { id = state.id, changedtick = 1, quickfixtextfunc = 1 })
        if list.changedtick == state.tick and rawequal(list.quickfixtextfunc, state.formatter) then
          set(state.win, state.id, '')
          redraw(state.win, state.id)
        end
      end
    end
  end
  if not next(tracked) and option_hook then
    vim.api.nvim_del_autocmd(option_hook)
    option_hook = nil
  end
end

function M.raw()
  local win = vim.fn.getloclist(0, { filewinid = 0 }).filewinid
  local list = M.get(win and win > 0 and 0 or nil, { id = 0, idx = 0, items = 1, changedtick = 1, quickfixtextfunc = 1 })
  local item = list.items and list.items[list.idx]
  if not item then return end
  local state = lookup(list.id)
  local record = state and state.tick == list.changedtick and rawequal(list.quickfixtextfunc, state.formatter)
    and state.records and state.records[list.idx]
  return vim.tbl_extend('force', record or {}, { raw_text = item.text, item = item, index = list.idx })
end

return M
