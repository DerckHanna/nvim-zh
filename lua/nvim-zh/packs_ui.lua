local M = {}
local packs = require('nvim-zh.packs')

local function report(ok, message)
  if not ok then vim.notify('nvim-zh：' .. tostring(message), vim.log.levels.WARN) end
end

local function call(fn, ...)
  local ok, result = pcall(fn, ...)
  report(ok, result)
  return ok
end

local function filter(row, query)
  local remote = row.update or {}
  return table.concat({ row.name, row.id, row.description or '', remote.repository or '', remote.executable or '' }, ' ')
    :lower():find(query:lower(), 1, true) ~= nil
end

local function label(row)
  if row.job and not row.job.finished then return row.job.phase end
  if row.job and row.job.phase == '失败' then return '失败' end
  local state = row.state or {}
  if state.restart then return '待重启' end
  if row.installed and not row.enabled then
    return '已暂停 · ' .. row.selected .. (row.update and (' · 可更新至 ' .. row.update.version) or '')
  end
  if row.update and row.installed then return '可更新 ' .. row.selected .. ' → ' .. row.update.version end
  if row.installed then
    if state.reason then return state.reason end
    if state.active then
      if row.kind == 'plugin' and not row.target then return '等待目标或版本证据 · ' .. state.active end
      local adapter = require('nvim-zh.plugins').info()[row.id]
      if adapter and not adapter.active and not vim.iter(adapter.surfaces):any(function(_, surface)
        return surface.active
      end) then return '等待目标或版本证据 · ' .. state.active end
      return '已生效 · ' .. state.active
    end
    return '已安装 · ' .. row.selected
  end
  if state.reason then return '登记异常' end
  return row.update and (row.target and '可安装 · 已检测到目标' or '可安装') or '无兼容版本'
end

local function group(row)
  local state = row.state or {}
  local job = row.job or {}
  if state.restart or state.error or job.phase == '失败' or (job.phase and not job.finished)
    or (row.installed and row.update) then return 1 end
  return row.installed and 2 or 3
end

local function key(row) return row.source .. ':' .. row.id end

function M.lines(panel, header)
  local rows, checked, catalog_job = packs.rows()
  local selected = M.selection(panel) or panel.pack_selection
  table.sort(rows, function(a, b)
    local first, second = group(a), group(b)
    if first ~= second then return first < second end
    if (a.target == true) ~= (b.target == true) then return a.target == true end
    return key(a) < key(b)
  end)
  local lines, items = { header, '' }, {}
  local function add(text, item)
    lines[#lines + 1] = ' ' .. text
    if item then items[#lines] = item end
  end
  if catalog_job and (not catalog_job.finished or catalog_job.phase == '失败') then
    add(catalog_job.phase .. (catalog_job.message and ' · ' .. catalog_job.message or ''))
  elseif checked then
    add('目录更新于 ' .. os.date('%Y-%m-%d %H:%M', checked))
  end
  if panel.query and panel.query ~= '' then add('查找 ' .. panel.query) end
  local last_group, first, focused, remote
  for _, row in ipairs(rows) do
    remote = remote or (row.installed and row.source ~= 'local')
    if filter(row, panel.query or '') then
      local section = group(row)
      if section ~= last_group then
        add(({ '待处理', '已安装', '可用' })[section])
        last_group = section
      end
      add(row.name .. '  ' .. label(row), row)
      first = first or row
      if key(row) == selected then focused = row end
    end
  end
  if not checked then
    local entry = { id = '@catalog', source = '', refresh = true }
    add('获取可用包 · 按 Enter 或 r', entry)
    first = first or entry
    if key(entry) == selected then focused = entry end
  elseif not last_group then add('无匹配的包 · / 查找或 r 刷新目录') end
  add('')
  focused = focused or first
  local action = focused and 'Enter 操作 · ' or ''
  local shortcut = ''
  if focused and focused.update and not (focused.job and not focused.job.finished) then
    shortcut = focused.installed and ' · u 更新' or ' · i 安装'
  end
  add(action .. '/ 查找' .. shortcut)
  add('r 刷新目录' .. (remote and ' · U 批量更新' or '') .. ' · a 更多 · ? 帮助')
  panel.pack_items = items
  return lines
end

function M.current(panel)
  return panel.pack_items and panel.pack_items[vim.api.nvim_win_get_cursor(panel.win)[1]]
end

function M.selection(panel)
  local row = M.current(panel)
  return row and key(row)
end

function M.restore(panel, selected)
  local items = panel.pack_items
  if not items then return end
  local first
  for _, line in ipairs(vim.fn.sort(vim.tbl_keys(items), 'n')) do
    first = first or line
    if key(items[line]) == selected then
      vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
      return
    end
  end
  local line = vim.api.nvim_win_get_cursor(panel.win)[1]
  if first and not items[line] then vim.api.nvim_win_set_cursor(panel.win, { first, 0 }) end
end

function M.move(panel, step)
  local lines = vim.fn.sort(vim.tbl_keys(panel.pack_items or {}), 'n')
  local line = vim.api.nvim_win_get_cursor(panel.win)[1]
  if step < 0 then lines = vim.fn.reverse(lines) end
  for _, target in ipairs(lines) do
    if (target - line) * step > 0 then vim.api.nvim_win_set_cursor(panel.win, { target, 0 }); return end
  end
end

local function valid(panel)
  return panel.pack_items and vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_win_get_buf(panel.win) == panel.buf
end

local function select(panel, items, prompt, action)
  vim.ui.select(items, { prompt = prompt, format_item = function(item) return item.text end }, function(item)
    if item and valid(panel) then action(item) end
  end)
end

local function confirm(panel, prompt, text, action)
  select(panel, { { text = '取消' }, { text = text, apply = true } }, prompt, function(item)
    if item.apply then action() end
  end)
end

local function refresh() packs.refresh_catalog(report) end

local function update_all(panel)
  packs.refresh_catalog(function(ok, message)
    if not valid(panel) then return end
    local commands = require('nvim-zh.pack_commands')
    local rows = commands.updates()
    if #rows == 0 then
      return vim.notify(ok and '暂无兼容更新' or tostring(message))
    end
    local versions = {}
    for _, row in ipairs(rows) do versions[#versions + 1] = row.id .. ' → ' .. row.update.version end
    confirm(panel, '更新 ' .. table.concat(versions, '、') .. '（适配变化将在重启后生效）', '更新这些包',
      function() commands.update_all(rows, report) end)
  end)
end

local function import(panel)
  vim.ui.input({ prompt = '本地汉化包路径', completion = 'file' }, function(path)
    if not path or path == '' or not valid(panel) then return end
    local ok, item = pcall(packs.inspect, path)
    if not ok then report(false, item); return end
    local description = item.id .. ' ' .. item.version .. ' · ' .. path
    confirm(panel, description, item.lua and '允许 Lua 入口并导入' or '导入',
      function() call(packs.import, path, item.lua, item.sha256) end)
  end)
end

function M.actions(panel, row)
  if not row then return end
  if row.refresh then return refresh() end
  local items = {}
  local function add(text, action) items[#items + 1] = { text = text, action = action } end
  if row.job and not row.job.finished then
    add('取消任务', function() packs.cancel(row.id) end)
  else
    if row.update then
      add(row.installed and ('更新至 ' .. row.update.version) or ('安装 ' .. row.update.version),
        function() packs.install(row.update, report) end)
    end
    if row.options and #row.options > 1 then
      add('选择兼容版本', function()
        local versions = {}
        for _, option in ipairs(row.options) do versions[#versions + 1] = { text = option.version, option = option } end
        select(panel, versions, '选择发行版本', function(item) packs.install(item.option, report) end)
      end)
    end
    if row.installed then
      local operation = row.enabled and 'disable' or 'enable'
      add(row.enabled and '暂停' or '恢复', function() call(packs.change, row.id, operation, row.generation) end)
      if row.previous then
        add('回滚至 ' .. row.previous, function()
          confirm(panel, row.id .. ' → ' .. row.previous, '回滚', function() call(packs.change, row.id, 'rollback', row.generation) end)
        end)
      end
      add('卸载', function()
        confirm(panel, '卸载 ' .. row.id .. ' 后相关界面使用上游文案', '卸载 ' .. row.id,
          function() call(packs.change, row.id, 'remove', row.generation) end)
      end)
    end
  end
  local state = row.state or {}
  local description = { row.name, row.source, label(row) }
  if row.description then description[#description + 1] = row.description end
  if row.selected then description[#description + 1] = '选定 ' .. row.selected end
  if state.active then description[#description + 1] = '活动 ' .. state.active end
  if row.job and row.job.message then description[#description + 1] = row.job.message end
  if #items == 0 then add('刷新目录', refresh) end
  select(panel, items, table.concat(description, ' · '), function(item) item.action() end)
end

function M.key(panel, pressed, render)
  local row = M.current(panel)
  if pressed == 'r' then refresh()
  elseif pressed == 'U' then update_all(panel)
  elseif pressed == '/' then
    vim.ui.input({ prompt = '查找汉化包', default = panel.query or '' }, function(query)
      if query ~= nil and valid(panel) then panel.query = query; render() end
    end)
  elseif pressed == 'a' then
    select(panel, { { text = '刷新目录', action = refresh },
      { text = '更新已安装的包', action = function() update_all(panel) end },
      { text = '导入本地包', action = function() import(panel) end },
    }, '汉化包操作', function(item) item.action() end)
  elseif pressed == '<CR>' then M.actions(panel, row)
  elseif row and row.update and ((pressed == 'i' and not row.installed) or (pressed == 'u' and row.installed)) then
    packs.install(row.update, report)
  end
end

return M
