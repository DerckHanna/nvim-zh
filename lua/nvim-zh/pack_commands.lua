local M = {}
local packs = require('nvim-zh.packs')

local function notify(ok, message)
  if not message then return end
  vim.notify('nvim-zh：' .. message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
end

local function request(value)
  local name, version = value:match('^([^@]+)@?([^@]*)$')
  assert(name, '无效的名称或版本')
  local source, id = name:match('^([^:]+):([^:]+)$')
  return id or name, source, version ~= '' and version or nil
end

local function matching(value)
  local id, source, version = request(value)
  local matches = {}
  for _, row in ipairs(packs.rows()) do
    if row.id == id and (not source or row.source == source) then
      matches[#matches + 1] = row
    end
  end
  assert(#matches <= 1, '请用 来源:包ID 选定发布源')
  return matches[1], version
end

function M.updates()
  local rows = {}
  for _, row in ipairs(packs.rows()) do
    if row.installed and row.update and not (row.job and not row.job.finished) then
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return rows
end

function M.update_all(rows, callback)
  for _, row in ipairs(rows) do packs.install(row.update, callback) end
end

local function install(value)
  local row, version = matching(value)
  local function candidate()
    row = matching(value)
    assert(row, '找不到汉化包，请检查名称和发布源')
    for _, option in ipairs(row.options or {}) do
      if version and version == option.version then return option end
    end
    if not version and row.update then return row.update end
    error('请选择发行版本，当前目标没有已验证的自动推荐', 0)
  end
  if row and not version and row.update then
    packs.install(row.update, notify)
  elseif row and version then
    packs.install(candidate(), notify)
  else
    packs.refresh_catalog(function(ok, message)
      local selected, result = pcall(candidate)
      if selected then packs.install(result, notify)
      else notify(false, ok and tostring(result) or message) end
    end)
  end
end

local function update(value)
  packs.refresh_catalog(function(ok, message)
    if value then
      local matched, row = pcall(matching, value)
      if not matched then return notify(false, tostring(row)) end
      if not row or not row.installed then return notify(false, '包尚未安装') end
      if row.update then return packs.install(row.update, notify) end
      return notify(ok, ok and '暂无兼容更新' or message)
    end
    local rows = M.updates()
    if #rows == 0 then return notify(ok, ok and '暂无兼容更新' or message) end
    M.update_all(rows, notify)
  end)
end

function M.run(command)
  local args = command.fargs
  local action, value = args[1], args[2]
  if not action then
    local _, err = require('nvim-zh.tui').open('packs')
    if err then notify(false, err) end
    return
  end
  if action == 'list' or action == 'search' then
    local function list()
      local result = {}
      for _, row in ipairs(packs.rows()) do
        if (action == 'search' or row.installed)
          and (not value or (row.name .. ' ' .. row.id):lower():find(value:lower(), 1, true)) then
          result[#result + 1] = row.source .. ':' .. row.id .. (row.selected and (' @' .. row.selected) or '')
        end
      end
      table.sort(result)
      local message = #result > 0 and table.concat(result, '\n') or '暂无匹配的包'
      notify(true, message)
    end
    list()
  elseif action == 'install' then
    install(assert(value, '请输入包 ID'))
  elseif action == 'update' then
    update(value)
  elseif action == 'import' then
    local path = assert(value, '请输入附件路径')
    if command.bang then notify(true, '允许执行适配入口：' .. packs.inspect(path).id .. ' · ' .. path) end
    local id = packs.import(path, command.bang)
    notify(true, (packs.info()[id] or {}).reason or (id .. ' 已导入'))
  elseif vim.tbl_contains({ 'enable', 'disable', 'rollback', 'remove' }, action) then
    local id = assert(value, '请输入包 ID')
    packs.change(id, action)
    notify(true, (packs.info()[id] or {}).reason or (id .. ' 操作完成'))
  else
    error('未知的汉化包操作：' .. action, 0)
  end
end

function M.complete(lead, line)
  local actions = { 'list', 'search', 'install', 'update', 'import', 'enable', 'disable', 'rollback', 'remove' }
  local action = line:match('^%s*NvimZhPacks!?%s+(%S+)%s')
  if action == 'import' then return vim.fn.getcompletion(lead, 'file') end
  local names = actions
  if action then
    names = {}
    local counts = {}
    for _, row in ipairs(packs.rows()) do counts[row.id] = (counts[row.id] or 0) + 1 end
    for _, row in ipairs(packs.rows()) do
      if row.installed or action == 'install' then
        names[#names + 1] = counts[row.id] > 1 and row.source .. ':' .. row.id or row.id
      end
    end
  end
  return vim.tbl_filter(function(name) return vim.startswith(name, lead) end, names)
end

return M
