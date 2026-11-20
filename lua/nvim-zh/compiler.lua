local M = {}
local engine = require('nvim-zh.engine')
local packs = require('nvim-zh.packs')
local config = {}
local group
local last
local probes = {}
local tracked = {}
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

local function probe(executable, name)
  local path = vim.fn.exepath(executable)
  if path == '' then return nil end
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil end
  local key = vim.inspect({ stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime })
  local cached = probes[path]
  if cached and cached.key == key then return cached.identity end
  local ok, identity = pcall(function()
    local version = vim.system({ path, '--version' }, { text = true }):wait(2500)
    local hash = vim.system({ 'sha256sum', '--', path }, { text = true }):wait(2500)
    local pattern = name == 'clang-tidy' and 'LLVM version (%d+%.%d+%.%d+)' or '^clang version (%d+%.%d+%.%d+)'
    return { executable = name, version = version.code == 0 and version.stdout:match(pattern) or nil,
      sha256 = hash.code == 0 and hash.stdout:match('^(%x+)') or nil }
  end)
  if not ok then identity = nil end
  probes[path] = { key = key, identity = identity }
  return identity
end

local function get_list(win, what)
  if win then return vim.fn.getloclist(win, what) end
  return vim.fn.getqflist(what)
end

local function set_formatter(win, id, formatter)
  local options = { id = id, quickfixtextfunc = formatter }
  if win then return vim.fn.setloclist(win, {}, 'a', options) end
  return vim.fn.setqflist({}, 'a', options)
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

function M.match_message(domain, body, code, level, interface)
  local contexts = {}
  if domain == 'clang-tidy' then
    if code then contexts[1] = level == 'note' and code .. '/note' or code end
    if level == 'note' then contexts[#contexts + 1] = 'fix_note' end
  else
    local warning = code and (code:match(',(%-W[^,]+)$') or code)
    if warning then contexts[#contexts + 1] = warning end
    if interface == 'driver' then contexts[#contexts + 1] = 'driver'
    elseif level == 'note' then contexts[#contexts + 1] = 'note'
    else contexts[#contexts + 1] = 'diagnostic' end
  end
  for _, context in ipairs(contexts) do
    local result, status, id = engine.translate({
      domain = domain, context = context, msgid = body, formatted = true, observe = false, report_ambiguity = true,
    })
    if status == 'ambiguous' then return body, status end
    if status == 'translated' then return result, status, context, id end
  end
  return body, 'missing_translation'
end

local function source_guard(item, files)
  if item.bufnr == 0 or item.lnum == 0 then return false end
  local file = files[item.bufnr]
  if file == nil then
    local path = vim.api.nvim_buf_get_name(item.bufnr)
    local stat = vim.uv.fs_stat(path)
    local ok, lines
    if stat and stat.type == 'file' and stat.size < 4 * 1024 * 1024 then
      ok, lines = pcall(vim.fn.readfile, path)
    end
    file = ok and lines or false
    files[item.bufnr] = file
  end
  if not file or not file[item.lnum] then return false end
  for i = item.lnum, 1, -1 do
    -- Clang flattens backslash-newline before processing directives.
    local line = file[i]:gsub('/%*.-%*/', ' '):gsub('^%s*%%:', '#'):gsub('^%s*%?%?=', '#')
    if line:match('^%s*#%s*error%f[%W]') or line:match('^%s*#%s*warning%f[%W]')
      or line:match('^%s*#%s*pragma%s+message%f[%W]') then return false end
    if i == 1 or not file[i - 1]:match('\\%s*$') then break end
  end
  return true
end

local function inspect_items(items, evidence)
  local result, files, previous, parent = {}, {}, nil, nil
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
    if interface == 'driver' and not level then
      local origin = (item.bufnr ~= 0 and vim.fs.basename(vim.api.nvim_buf_get_name(item.bufnr)))
        or body:match('^([^:]+):')
      origin = origin and vim.fs.basename(origin)
      if origin and (origin == 'ld' or origin:match('^ld[%.%-]') or origin == 'lld' or origin == 'as') then
        record.tool, record.version, record.reason = origin, nil, 'subtool_output'
      end
    elseif item.valid == 1 or interface == 'driver' then
      local driver = interface == 'driver' and evidence.domain == 'clang'
        and (prefix:find(evidence.identity.executable .. ': ', 1, true) == 1
          or (item.bufnr ~= 0 and vim.fs.basename(vim.api.nvim_buf_get_name(item.bufnr)) == evidence.identity.executable))
      if level ~= 'note' then previous, parent = code, record end
      if evidence.domain == 'clang-tidy' and level == 'note' and not code then
        code = previous
        record.code = code
      end
      if level == 'note' and parent and message:find("from 'diagnose_if' attribute", 1, true) then
        parent.reason, parent.text = 'project_text', parent.raw_text
      end
      local warning = code and (code:match(',(%-W[^,]+)$') or code)
      if (warning and free_codes[warning]) or (interface ~= 'driver' and not source_guard(item, files)) then
        record.reason = 'project_text'
      elseif driver or (interface ~= 'driver' and evidence.source_locations) then
        local translated, reason, context, id = M.match_message(evidence.domain, message, code, level, interface)
        record.reason, record.context, record.entry_id = reason, context, id
        if reason == 'translated' then
          record.text = prefix .. translated .. (record.code and body ~= vim.trim(text) and (' [' .. record.code .. ']') or '')
        end
      end
    end
  end
  return result
end

local function display_line(item, record)
  if not record or record.reason ~= 'translated' then return '' end
  local name = item.module ~= '' and item.module or (item.bufnr ~= 0 and vim.fn.bufname(item.bufnr) or '')
  local location = item.lnum > 0 and tostring(item.lnum) or ''
  if item.end_lnum > 0 and item.end_lnum ~= item.lnum then location = location .. '-' .. item.end_lnum end
  if item.col > 0 then location = location .. ' col ' .. item.col end
  if item.end_col > 0 and item.end_col ~= item.col then location = location .. '-' .. item.end_col end
  if item.lnum > 0 and item.type ~= '' then location = location .. ' ' .. (levels[item.type:lower()] or item.type) end
  if item.nr > 0 then location = location .. (' %3d'):format(item.nr) end
  return name .. '|' .. location .. '| ' .. record.text:gsub('\n', ' ')
end

local function act(event)
  local loc = event.match == 'lmake'
  if not config.enabled or not (loc and config.loclist or not loc and config.quickfix) then return end
  local win = loc and vim.api.nvim_get_current_win() or nil
  local list = get_list(win, { id = 0, title = 1, items = 1, quickfixtextfunc = 1, changedtick = 1, winid = 0 })
  local command = vim.trim((list.title or ''):sub(2))
  local domain, executable, name, args = direct_command(command)
  last = { list = loc and 'loclist' or 'quickfix', tool = domain, reason = 'unknown_source' }
  if not domain then return end
  if not vim.version.eq(vim.version(), '0.12.6') then last.reason = 'unverified_interface'; return end
  local identity = probe(executable, name)
  local reason = packs.tool_reason(domain, identity, 'quickfix')
  last.version, last.reason = identity and identity.version, reason
  if reason ~= 'verified' then return end
  if vim.o.quickfixtextfunc ~= '' or list.quickfixtextfunc ~= '' then
    last.reason = 'external_override'
    return
  end
  -- These options can change diagnostic ownership, location or output schema.
  -- Keep the display unmodified for those invocations.
  local source_locations = domain == 'clang-tidy'
  for _, arg in ipairs(args) do
    if arg:match('^[@]') or arg:match('^%-X') or arg:match('^%-fplugin')
      or arg:match('^%-%-config') or arg:match('^%-fdiagnostics%-format')
      or arg:match('^%-fno%-diagnostics%-show%-option') or arg:match('^%-%-load')
      or arg:match('^%-%-experimental%-custom%-checks') or arg:match('^%-%-extra%-arg') then
      last.reason = 'unverified_interface'
      return
    end
    source_locations = source_locations or arg == '-fsyntax-only' or arg == '-c' or arg == '-E' or arg == '-S'
  end
  local evidence = { domain = domain, identity = identity, source_locations = source_locations }
  if not evidence.source_locations then last.reason = 'driver_only' end
  local state = { id = list.id, evidence = evidence, win = win }
  local formatter = function(info)
    if not config.enabled or not (info.quickfix == 1 and config.quickfix or info.quickfix == 0 and config.loclist)
      or packs.tool_reason(domain, identity, 'quickfix') ~= 'verified' then return {} end
    local current = get_list(info.quickfix == 0 and info.winid or nil, { id = info.id, items = 1, changedtick = 1 })
    if state.tick ~= current.changedtick then return {} end
    local lines = {}
    for i = info.start_idx, info.end_idx do
      lines[#lines + 1] = display_line(current.items[i], state.records[i])
    end
    return lines
  end
  state.records = inspect_items(list.items, evidence)
  state.tick = list.changedtick + 1
  if set_formatter(win, list.id, formatter) ~= 0 then last.reason = 'projection_failed'; return end
  state.tick = get_list(win, { id = list.id, changedtick = 1 }).changedtick
  tracked[list.id % 64] = state
  if list.winid and list.winid ~= 0 and vim.api.nvim_win_is_valid(list.winid) then
    vim.api.nvim_win_call(list.winid, function()
      local view = vim.fn.winsaveview()
      vim.cmd(loc and 'silent noautocmd lopen' or 'silent noautocmd copen')
      vim.fn.winrestview(view)
    end)
  end
  local counts = {}
  for _, row in ipairs(state.records) do counts[row.reason] = (counts[row.reason] or 0) + 1 end
  last.results = counts
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'NvimZhChanged', modeline = false })
end

function M.setup(opts)
  config = vim.deepcopy(opts)
  if group or not config.enabled then return end
  group = vim.api.nvim_create_augroup('NvimZhCompiler', { clear = true })
  vim.api.nvim_create_autocmd('QuickFixCmdPost', { group = group, pattern = { 'make', 'lmake' },
    callback = function(event)
      local ok, err = pcall(act, event)
      if not ok then last = { reason = 'projection_failed', error = tostring(err) } end
    end })
end

function M.teardown()
  config = {}
  if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
  last, probes = nil, {}
end

function M.raw()
  local win = vim.fn.getloclist(0, { filewinid = 0 }).filewinid
  local list = get_list(win and win > 0 and 0 or nil, { id = 0, idx = 0, items = 1, changedtick = 1 })
  local item = list.items and list.items[list.idx]
  if not item then return end
  local state = tracked[list.id % 64]
  local record = state and state.id == list.id and state.tick == list.changedtick and state.records[list.idx]
  return vim.tbl_extend('force', { raw_text = item.text }, record or {}, { item = item, index = list.idx })
end

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
