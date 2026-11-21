local M = {}
local match_message = require('nvim-zh.tool_message').match_message
local catalog = require('nvim-zh.catalog')
local packs = require('nvim-zh.packs')
local lists = require('nvim-zh.list_display')
local config = {}
local group
local last
local probes = {}
local generation = 0
local levels = { e = 'error', w = 'warning', n = 'note', i = 'info', f = 'error', r = 'remark' }
local free_codes = {
  ['-W#warnings'] = true, ['-W#pragma-messages'] = true, ['-Wuser-defined-warnings'] = true,
  ['-Wapinotes'] = true, ['-Wsource-mgr'] = true, ['-Winline-asm'] = true,
}
local domains = { clang = 'clang', ['clang++'] = 'clang', ['clang-tidy'] = 'clang-tidy' }

-- Only recognize direct invocations with simple shell arguments. Do not infer
-- which tool produced a recipe's output from a buffer-local compiler setting.
local function direct_command(command)
  if command:find('[;&|$<>`\r\n\\]') then return end
  local args = {}
  while command ~= '' do
    local arg, next_arg = command:match('^"([^"]*)"%f[%s%z]()')
    if not arg then arg, next_arg = command:match("^'([^']*)'%f[%s%z]()") end
    if not arg then arg, next_arg = command:match('^([^%s\'"]+)%f[%s%z]()') end
    if not arg then return end
    args[#args + 1] = arg
    command = vim.trim(command:sub(next_arg))
  end
  local executable = args[1]
  if not executable or executable == '' then return end
  local name = vim.fs.basename(executable)
  if domains[name] then return domains[name], executable, name, args end
end

local function tool_path(executable)
  local path = vim.fn.exepath(executable)
  if path == '' then return end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return end
  return path, table.concat({ stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec,
    stat.ctime.sec, stat.ctime.nsec }, ':')
end

function M.identity(executable)
  local path, key = tool_path(executable)
  local cached = path and probes[path]
  if cached and cached.key == key then return cached.identity end
end

local function probe(executable, name, done)
  local path, key = tool_path(executable)
  if not path then done(); return end
  local cached = probes[path]
  if cached and cached.key == key then
    if cached.pending then cached.pending[#cached.pending + 1] = done else done(cached.identity) end
    return
  end
  local entry = { key = key, pending = { done } }
  probes[path] = entry
  local results, remaining = {}, 2
  local function received(kind, result)
    if probes[path] ~= entry then return end
    results[kind] = result
    remaining = remaining - 1
    if remaining ~= 0 then return end
    local pending = entry.pending
    entry.pending = nil
    local current_path, current_key = tool_path(executable)
    if path == current_path and key == current_key then
      local version, hash = results.version, results.hash
      local pattern = name == 'clang-tidy' and 'LLVM version (%d+%.%d+%.%d+)' or '^clang version (%d+%.%d+%.%d+)'
      entry.identity = { executable = name, version = version.code == 0 and version.stdout:match(pattern) or nil,
        sha256 = hash.code == 0 and hash.stdout:match('^(%x+)') or nil, path = path, key = key }
    end
    for _, callback in ipairs(pending) do
      local ok, err = pcall(callback, entry.identity)
      if not ok then last = { reason = 'projection_failed', error = tostring(err) } end
    end
  end
  local function run(kind, argv)
    local ok = pcall(vim.system, argv, { text = true, timeout = 2500 }, vim.schedule_wrap(function(result)
      received(kind, result)
    end))
    if not ok then received(kind, { code = -1 }) end
  end
  run('version', { path, '--version' })
  run('hash', { 'sha256sum', '--', path })
end

local function split(text, domain)
  local body, code = text:match('^(.*) %[(.-)%]$')
  if code and (domain == 'clang' and code:match('^%-W[%w_#%-,]+$')
    or domain == 'clang-tidy' and code:match('^[%w_%-%.]+%-[%w_%-%.]+$')) then
    return body, code
  end
  return text
end

local function classify(body, level)
  local prefix = body:match('^(fatal error: )') or body:match('^(error: )') or body:match('^(warning: )')
    or body:match('^(note: )') or body:match('^(remark: )')
  if prefix then return body:sub(#prefix + 1), prefix:match('^(.-):'), prefix end
  return body, level, ''
end

local function loose_item(item)
  return item.bufnr == 0 and item.lnum == 0 and item.type == ''
end

local function source_line(items, index, line)
  for i = index + 1, #items do
    local row = items[i]
    if not loose_item(row) then break end
    local number, snippet = row.text:match('^%s+(%d+) | (.*)$')
    if not number then break end
    if tonumber(number) == line then return snippet end
  end
end

local function continuation(line)
  return line:match('^(.-)\\%s*$') or line:match('^(.-)%?%?/%s*$')
end

local function source_guard(item, files, bounds, snippet, tabstop)
  if item.bufnr == 0 or item.lnum == 0 then return 'unverified_location' end
  local file = files[item.bufnr]
  if file == nil then
    local path = vim.api.nvim_buf_get_name(item.bufnr)
    local stat = vim.uv.fs_stat(path)
    local ok, lines
    if stat and stat.type == 'file' and stat.size < 4 * 1024 * 1024 then
      ok, lines = pcall(vim.fn.readfile, path, '', bounds[item.bufnr] + 16)
    end
    file = ok and lines or false
    files[item.bufnr] = file
  end
  local line = file and file[item.lnum]
  if not line then return 'unverified_location' end
  if not snippet then return 'unverified_location' end
  if snippet ~= line then
    local column = 0
    local expanded = line:gsub('([^\t]*)\t', function(before)
      column = column + vim.fn.strdisplaywidth(before)
      local width = tabstop - column % tabstop
      column = column + width
      return before .. (' '):rep(width)
    end)
    if snippet ~= expanded then return 'unverified_location' end
  end

  local first = item.lnum
  while first > 1 and continuation(file[first - 1]) do first = first - 1 end
  local parts = {}
  for i = first, #file do
    local fragment = continuation(file[i])
    parts[#parts + 1] = fragment or file[i]
    if not fragment then break end
    if i == #file then return 'unverified_location' end
  end
  local logical = table.concat(parts):gsub('^\239\187\191', ''):gsub('/%*.-%*/', ' ')
    :gsub('^%s*%%:', '#'):gsub('^%s*%?%?=', '#')
  local directive = logical:match('^%s*#%s*([%a_]+)')
  -- A block comment can start on the preceding physical line and close
  -- immediately before a diagnostic directive's name.
  if directive == 'error' or directive == 'warning' or directive == 'pragma'
    or line:sub(1, item.col):find('*/', 1, true) then return 'project_text' end
end

local function inspect_items(items, evidence)
  local result, files, previous, parent = {}, {}, nil, nil
  local include_stack, bounds = {}, {}
  for _, item in ipairs(items) do
    if item.bufnr ~= 0 and item.lnum > 0 then
      bounds[item.bufnr] = math.max(bounds[item.bufnr] or 0, item.lnum)
    end
  end
  for index, item in ipairs(items) do
    local text = item.text
    local body, code = split(vim.trim(text), evidence.domain)
    local message, level, prefix = classify(body, levels[item.type:lower()])
    if not level and item.lnum == 0 then
      local tool, tail = body:match('^([^:]+): (.+)$')
      if tool == evidence.identity.executable then
        message, level, prefix = classify(tail)
        prefix = tool .. ': ' .. prefix
      end
    end
    local interface = item.lnum == 0 and 'driver' or 'quickfix'
    local record = { raw_text = text, code = code, level = level, text = text,
      tool = evidence.domain, version = evidence.identity.version, reason = 'unclassified_output' }
    result[index] = record
    if evidence.domain == 'clang' and evidence.source_locations and loose_item(item)
      and (text:match('^In file included from .+:[1-9]%d*:$') or text == 'In included file:') then
      include_stack[#include_stack + 1] = record
    elseif interface == 'driver' and not level then
      include_stack = {}
      local origin = (item.bufnr ~= 0 and vim.fs.basename(vim.api.nvim_buf_get_name(item.bufnr)))
        or body:match('^([^:]+):')
      origin = origin and vim.fs.basename(origin)
      if origin and (origin == 'ld' or origin:match('^ld[%.%-]') or origin == 'lld' or origin == 'as') then
        record.tool, record.version, record.reason = origin, nil, 'subtool_output'
      end
    elseif item.valid == 1 or interface == 'driver' then
      local driver = interface == 'driver' and evidence.domain == 'clang'
        and (prefix:find(evidence.identity.executable .. ': ', 1, true) == 1
          or (item.bufnr ~= 0 and vim.fs.basename(vim.api.nvim_buf_get_name(item.bufnr)) == evidence.identity.executable)
          or (evidence.frontend_only and loose_item(item) and prefix ~= ''))
      if level ~= 'note' then previous, parent = code, record end
      if evidence.domain == 'clang-tidy' and level == 'note' and not code then
        code = previous
        record.code = code
      end
      if level == 'note' and parent and message:find("from 'diagnose_if' attribute", 1, true) then
        parent.reason, parent.text = 'project_text', parent.raw_text
      end
      local warning = code and (code:match(',(%-W[^,]+)$') or code)
      local location_reason
      if interface ~= 'driver' then
        local snippet = source_line(items, index, item.lnum)
        if evidence.domain == 'clang-tidy' and level == 'note' and code == nil then
          location_reason = 'unverified_location'
        else
          location_reason = source_guard(item, files, bounds, snippet, evidence.tabstop)
        end
      end
      if warning and free_codes[warning] then
        record.reason = 'project_text'
      elseif location_reason then
        record.reason = location_reason
      elseif driver or (interface ~= 'driver' and evidence.source_locations) then
        local translated, reason, context, id, nested =
          match_message(evidence.domain, message, code, level, interface)
        record.reason, record.context, record.entry_id, record.nested_entry_id = reason, context, id, nested
        if reason == 'translated' then
          record.text = prefix .. translated .. (record.code and body ~= vim.trim(text) and (' [' .. record.code .. ']') or '')
        end
      end
      if interface ~= 'driver' and not location_reason and evidence.source_locations then
        for _, preamble in ipairs(include_stack) do
          preamble.text, preamble.reason, preamble.context, preamble.entry_id =
            match_message('clang', preamble.raw_text, nil, nil, 'include_stack')
        end
      end
      include_stack = {}
    end
  end
  return result
end

local function act(event)
  local loc = event.match == 'lmake'
  if not config.enabled or not (loc and config.loclist or not loc and config.quickfix) then return end
  local win = loc and vim.api.nvim_get_current_win() or nil
  local list = lists.get(win, { id = 0, title = 1, quickfixtextfunc = 1, changedtick = 1 })
  local command = vim.trim((list.title or ''):sub(2))
  local domain, executable, name, args = direct_command(command)
  local observation = { list = loc and 'loclist' or 'quickfix', tool = domain, reason = 'unknown_source' }
  last = observation
  if not domain then return end
  if not vim.version.eq(vim.version(), '0.12.6') then observation.reason = 'unverified_interface'; return end
  if not lists.available(win, list, 'compiler') then observation.reason = 'external_override'; return end
  if not packs.has_tool(domain) then observation.reason = packs.tool_reason(domain); return end
  -- These options can change diagnostic ownership, location or output schema.
  -- Keep the display unmodified for those invocations.
  local source_locations, frontend_only = domain == 'clang-tidy', false
  local tabstop = 8
  if domain == 'clang' and vim.env.CCC_OVERRIDE_OPTIONS then
    last.reason = 'unverified_interface'
    return
  end
  for _, arg in ipairs(args) do
    if arg:match('^[@]') or arg:match('^%-X') or arg:match('^%-fplugin')
      or arg:match('^%-%-config') or arg:match('^%-fdiagnostics%-format')
      or arg:match('^%-fno%-diagnostics%-show%-option') or arg:match('^%-%-load')
      or arg:match('^%-%-experimental%-custom%-checks') or arg:match('^%-%-extra%-arg')
      or arg == '-fno-caret-diagnostics' or arg == '-fno-integrated-as' or arg:match('^%-B') then
      last.reason = 'unverified_interface'
      return
    end
    frontend_only = frontend_only or arg == '-fsyntax-only' or arg == '-E'
    source_locations = source_locations or frontend_only or arg == '-c' or arg == '-S'
    local requested_tabstop = domain == 'clang' and tonumber(arg:match('^%-ftabstop=(%d+)$'))
    if requested_tabstop and requested_tabstop >= 1 and requested_tabstop <= 100 then tabstop = requested_tabstop end
  end
  observation.reason = 'probing'
  local token = generation
  packs.ensure_tool(domain, true)
  local function apply_identity(identity)
    if token ~= generation or not config.enabled or not (loc and config.loclist or not loc and config.quickfix)
      or (win and not vim.api.nvim_win_is_valid(win)) then return end
    local current = lists.get(win, { id = 0, changedtick = 1, quickfixtextfunc = 1 })
    if current.id ~= list.id or current.changedtick ~= list.changedtick or not lists.available(win, current, 'compiler') then
      if last == observation then observation.reason = 'stale_list' end
      return
    end
    if not packs.ensure_tool(domain, true, function() apply_identity(identity) end) then return end
    local reason = packs.tool_reason(domain, identity, 'quickfix')
    observation.version, observation.reason = identity and identity.version, reason
    if reason == 'verified' then
      if not source_locations then observation.reason = 'driver_only' end
      list.items = lists.get(win, { id = list.id, items = 1 }).items
      local evidence = { domain = domain, identity = identity, source_locations = source_locations,
        frontend_only = frontend_only, tabstop = tabstop }
      local records = lists.install(win, list, 'compiler', function(items) return inspect_items(items, evidence) end, function()
        if not config.enabled or not (loc and config.loclist or not loc and config.quickfix)
          or packs.tool_reason(domain, identity, 'quickfix') ~= 'verified' then return end
        local path, key = tool_path(executable)
        if path == identity.path and key == identity.key then return catalog.revision(domain) end
      end)
      if not records then observation.reason = 'projection_failed'; return end
      local counts = {}
      for _, row in ipairs(records) do counts[row.reason] = (counts[row.reason] or 0) + 1 end
      observation.results = counts
    end
    require('nvim-zh.runtime').changed('adapters')
  end
  probe(executable, name, apply_identity)
end

function M.setup(opts)
  config = vim.deepcopy(opts)
  if config.enabled then
    lists.refresh('compiler')
    if not group then
      group = vim.api.nvim_create_augroup('NvimZhCompiler', { clear = true })
      vim.api.nvim_create_autocmd('QuickFixCmdPost', { group = group, pattern = { 'make', 'lmake' },
        callback = function(event)
          local ok, err = pcall(act, event)
          if not ok then last = { reason = 'projection_failed', error = tostring(err) } end
        end })
    end
  else
    generation = generation + 1
    if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
    lists.clear('compiler')
  end
end

function M.teardown()
  generation = generation + 1
  config = {}
  if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
  last, probes = nil, {}
  lists.clear('compiler')
end

M.raw = lists.raw

function M.raw_text()
  local row = M.raw()
  if not row then return '没有可读取的 quickfix 或 location list 条目' end
  local fields = { '原文：' .. row.raw_text }
  if row.code then fields[#fields + 1] = '代码：' .. row.code end
  if row.tool then fields[#fields + 1] = '来源：' .. row.tool .. ' ' .. (row.version or '') end
  return table.concat(fields, ' · ')
end

function M.info()
  return { enabled = config.enabled == true, quickfix = config.quickfix == true,
    loclist = config.loclist == true, last = vim.deepcopy(last) }
end

return M
