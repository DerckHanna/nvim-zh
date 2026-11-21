local M = {}
local spec = assert((...), '缺少 nvim-cmp 适配清单')
local context
local defaults = setmetatable({}, { __mode = 'k' })
local formatted = setmetatable({}, { __mode = 'k' })
local observations = {}
local wipeout
local loaded = {}

local edits = {
  cmp = {
    { 300, 'ready source names' },
    { 308, 'unavailable source names' },
    { 316, 'unused source names' },
    { 324, 'unknown source names' },
  },
  ['cmp.config'] = {
    { 185, ' is deprecated.\\n' }, { 186, '[nvim-cmp] Please use ' }, { 188, ' instead.' },
    { 200, ' is deprecated.\\n' }, { 201, '[nvim-cmp] Please use ' }, { 203, ' instead.' },
    { 218, ' is deprecated.\\n' }, { 219, '[nvim-cmp] Please use ' }, { 221, ' instead.' },
  },
}

local function translate(surface, key, text)
  if context and context.enabled() and context.verify(surface) then
    return context.translate(spec.domain, key, text)
  end
  return text
end

local function replace(line, from, to)
  local first, last = line:find(from, 1, true)
  assert(first and not line:find(from, last + 1, true), 'nvim-cmp source projection mismatch')
  return line:sub(1, first - 1) .. to .. line:sub(last + 1)
end

local function kind(entry, item)
  local buf = entry.context.bufnr
  local owner = formatted[item]
  local actual = defaults[owner]
  local owns = actual and actual() or false
  local category = entry.completion_item.kind
  if type(buf) == 'number' and buf > 0 then observations[buf] = owns end
  if not owns or not item.kind or (entry.completion_item.cmp or {}).kind_text ~= nil
    or (category ~= nil and (type(category) ~= 'number' or category < 1 or category > 25 or category % 1 ~= 0)) then
    return item, nil
  end
  local display = translate('default_kind', 'kind', item.kind)
  if display == item.kind then return item, nil end
  return vim.tbl_extend('force', {}, item, { kind = display }), display
end

function M.project_source(module, bytes, path, current)
  local lines = vim.split(bytes, '\n', { plain = true })
  local function change(row, from, to)
    lines[row] = replace(lines[row], from, to)
  end
  if module == 'cmp' then
    for _, edit in ipairs(edits.cmp) do
      local row, title = unpack(edit)
      local literal = "'# " .. title .. "\\n'"
      change(row, literal, "('# ' .. cmpzh.text('status', '" .. title .. "') .. '\\n')")
    end
  elseif module == 'cmp.config' then
    for _, edit in ipairs(edits[module]) do
      local row, text = unpack(edit)
      local literal = "'" .. text .. "'"
      change(row, literal, "cmpzh.text('deprecation', " .. literal .. ')')
    end
  elseif module == 'cmp.config.default' then
    change(53, 'format = function', 'format = cmpzh.default(function')
    change(55, 'end,', 'end),')
  elseif module == 'cmp.entry' then
    change(274, 'suggest_offset, entries_buf)', 'suggest_offset, entries_buf, display_kind)')
    change(275, 'local item = self:get_vim_item(suggest_offset)',
      "local item = self:get_vim_item(suggest_offset); local key; if display_kind then item, key = cmpzh.kind(self, item) end")
    change(276, 'tostring(entries_buf)', "tostring(entries_buf) .. (key and (':' .. key) or '')")
    change(378, 'vim_item = config.get().formatting.format(self, vim_item)',
      'local format = config.get().formatting.format; vim_item = format(self, vim_item); cmpzh.mark(vim_item, format)')
  elseif module == 'cmp.view.custom_entries_view' then
    change(67, 'self.offset, buf)', 'self.offset, buf, true)')
    change(150, 'offset, entries_buf)', 'offset, entries_buf, true)')
    change(297, 'self.offset, entries_buf)', 'self.offset, entries_buf, true)')
  end
  local chunk = assert(loadstring('return function(cmpzh, ...) ' .. table.concat(lines, '\n') .. '\nend', '@' .. path))()
  local object, original
  local method = module == 'cmp' and 'status' or module == 'cmp.config' and 'normalize' or nil
  local function owns()
    return current() and (not method or object[method] == original)
  end
  local runtime = {
    text = function(key, msgid)
      if not owns() then return msgid end
      return translate(key, key, msgid)
    end,
    default = function(fn)
      defaults[fn] = owns
      return fn
    end,
    mark = function(item, fn)
      if type(item) == 'table' then formatted[item] = defaults[fn] and fn or nil end
    end,
    kind = function(entry, item)
      if owns() then return kind(entry, item) end
      return item, nil
    end,
  }
  return function(...)
    object = chunk(runtime, ...)
    original = method and object[method] or nil
    if method then loaded[module] = owns end
    return object
  end
end

function M.attach(ctx)
  context = ctx
  if not wipeout then
    wipeout = vim.api.nvim_create_autocmd('BufWipeout', { callback = function(event)
      observations[event.buf] = nil
    end })
  end
end

function M.detach()
  context = nil
  observations = {}
  if wipeout then vim.api.nvim_del_autocmd(wipeout); wipeout = nil end
end

function M.info(ctx)
  local slots, any = {}, false
  for name, module in pairs({ status = 'cmp', deprecation = 'cmp.config', default_kind = 'cmp.entry' }) do
    local verified, reason = ctx.verify(name)
    local override = name == 'default_kind' and observations[vim.api.nvim_get_current_buf()] == false
      or loaded[module] and not loaded[module]()
    local active = ctx.enabled() and verified ~= nil and not override
    slots[name] = { active = active, reason = active and nil or override and 'external_override' or reason }
    any = any or active
  end
  return { active = any, slots = slots, seam = 'verified nvim-cmp display expressions' }
end

return M
