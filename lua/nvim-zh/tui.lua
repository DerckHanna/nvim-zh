local M = {}
local panel
local names = { '概览', '汉化包', '翻译', '缺失', '检查' }
local PAGES = { overview = 1, packs = 2, translations = 3, missing = 4, health = 5 }
local labels = { ok = '已生效', idle = '未准备', unread = '尚未读取', disabled = '已关闭', degraded = '降级',
  unsupported = '不支持', preparing = '准备中', syncing = '同步中', error = '失败', restore_failed = '恢复失败' }

local function clean(value)
  return tostring(value == nil and '未知' or value):gsub('[%z\1-\31\127]', ' ')
end

local function short(value) return value and value:sub(1, 12) or '未知' end
local function status(value) return labels[value] or clean(value) end
local function explanation(value) return clean(value):gsub('^.-%.lua:%d+:%s*', '') end

local function lines()
  local info = require('nvim-zh.status').get()
  local version, runtime = info.version, info.runtime
  local tabs = {}
  for index, name in ipairs(names) do tabs[#tabs + 1] = index == panel.page and ('[' .. name .. ']') or name end
  local header = ' nvim-zh  ' .. table.concat(tabs, '  ')
  if panel.page == PAGES.packs then return require('nvim-zh.packs_ui').lines(panel, header) end
  local result = { header, '' }
  local function add(value) result[#result + 1] = ' ' .. clean(value) end
  if panel.page == PAGES.overview then
    add('插件运行版本：' .. version.running_version .. ' / ' .. short(version.running_implementation))
    add('磁盘安装版本：' .. (version.installed_version or '未检查') .. ' / ' .. short(version.installed_implementation))
    add('活动资源集：' .. short(version.active_bundle))
    add('同步状态：' .. status(runtime.status))
    add('实现更新：' .. (runtime.restart_required and '重启 Neovim 后自动生效' or '无待重启变化'))
    add('核心消息：' .. status(info.native.status))
    if info.native.reason then add('核心消息说明：' .. explanation(info.native.reason)) end
    add('中文 Help：' .. (info.config.modules.help.enabled and info.helplang or '已关闭'))
    add('Neovim：' .. info.nvim_version)
    add('本地配置：' .. (runtime.config_file.present == false and '未创建，使用 setup/default'
      or status(runtime.config_file.status)))
    add('本地配置路径：' .. runtime.config_file.path)
    if runtime.error then add('同步说明：' .. explanation(runtime.error)) end
    if runtime.config_file.error then add('配置说明：' .. explanation(runtime.config_file.error)) end
    add('')
    local installed, pending = 0, 0
    for _, row in ipairs(require('nvim-zh.packs').rows()) do
      if row.installed then installed = installed + 1 end
      if (row.installed and row.update) or (row.state and row.state.restart) then pending = pending + 1 end
    end
    add(('汉化包 · %d 已安装 · %d 待处理 · Enter 管理'):format(installed, pending))
    panel.pack_overview = #result
    add('主包更新由 vim.pack 管理。')
  elseif panel.page == PAGES.translations or panel.page == PAGES.missing then
    local stats = require('nvim-zh.engine').stats()
    if panel.page == PAGES.translations then
      local summary = version.summary
      if summary then
        add('翻译基准 Neovim：' .. summary.baseline)
        add(('中文 Help：%d 篇完整，%d 篇排除（以资源清单为准）'):format(summary.help.complete, summary.help.excluded))
        add('核心消息补充：' .. summary.native.supplement .. ' 条；不代表所有运行时消息均已验证。')
        local domains = vim.tbl_keys(summary.domains)
        table.sort(domains)
        for _, domain in ipairs(domains) do add(('目录 %s：%d 条已交付译文'):format(domain, summary.domains[domain])) end
      else add('尚无已验证资源清单。') end
      add('')
      if stats.runtime.observed == 0 then add('当前会话：暂无观察数据。')
      else add(('当前会话：%d 次已译 / %d 次观察，%d 次回退'):format(
        stats.runtime.translated, stats.runtime.observed, stats.runtime.fallback)) end
      add('统计仅限已接入的翻译入口，跨资源更新累计，非全 Neovim 覆盖率。')
      if not stats.missing.enabled then add('运行时观察已关闭。') end
      if stats.runtime.truncated then add('去重记录达到容量上限，部分记录已淘汰。') end
      local plugins = vim.tbl_keys(info.adapters)
      table.sort(plugins)
      for _, name in ipairs(plugins) do
        local adapter = info.adapters[name]
        add(('插件 %s：%s（%s）'):format(name, adapter.active and '已适配' or '未适配', adapter.reason or '正常'))
      end
    else
      local missing = require('nvim-zh.missing').list()
      add(('本地缺失：%d 条去重 / %d 次观察到回退；容量 %d'):format(
        stats.missing.unique, stats.missing.occurrences, stats.missing.capacity))
      add('仅展示脱敏记录，最多显示 2000 条；按出现次数排序，可用 / 搜索。')
      if not stats.missing.enabled then add('缺失记录已关闭。') end
      if #missing == 0 then add('没有观察到缺失翻译；这不代表所有文本均有译文。') end
      for index = 1, math.min(#missing, 2000) do
        local row = missing[index]
        add(('[%s/%s] %s（%d）'):format(row.domain, row.context, row.msgid, row.count))
      end
      if stats.missing.dropped > 0 then add('已因容量限制淘汰：' .. stats.missing.dropped .. ' 条记录。') end
    end
  else
    local health = require('nvim-zh.health').info()
    add('检查状态：' .. ({ unread = '未执行', checking = '检查中', complete = '已完成', error = '失败', cancelled = '已取消' })[health.status])
    if health.checked_at then add('检查时间：' .. os.date('%Y-%m-%d %H:%M:%S', health.checked_at)) end
    for _, row in ipairs(health.results) do
      local label = ({ ok = '通过', warn = '警告', error = '失败', info = '信息' })[row.status] or row.status
      add(('[%s] %s：%s'):format(label, row.name, row.message))
    end
    if health.error then add(health.error) end
  end
  result[#result + 1] = ''
  result[#result + 1] = ' Tab/Shift-Tab 切页 · j/k 滚动 · / 搜索 · ? 帮助 · q/Esc 关闭'
  return result
end

local function size()
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(28, vim.o.lines - 5))
  return { relative = 'editor', style = 'minimal', border = 'rounded', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)) }
end

function M.render()
  if not panel or not vim.api.nvim_win_is_valid(panel.win) then return end
  local pack_ui = panel.page == PAGES.packs and require('nvim-zh.packs_ui')
  local selected = pack_ui and (pack_ui.selection(panel) or panel.pack_selection)
  local next_lines = lines()
  local width = vim.api.nvim_win_get_width(panel.win)
  for index, text in ipairs(next_lines) do
    if vim.fn.strdisplaywidth(text) > width then
      local out = ''
      for _, char in ipairs(vim.fn.split(text, '\\zs')) do
        if vim.fn.strdisplaywidth(out .. char .. '…') > width then break end
        out = out .. char
      end
      next_lines[index] = width > 1 and out .. '…' or ''
    end
  end
  if vim.deep_equal(panel.lines, next_lines) then return end
  local view = vim.api.nvim_win_call(panel.win, vim.fn.winsaveview)
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, next_lines)
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_win_call(panel.win, function() vim.fn.winrestview(view) end)
  if pack_ui then pack_ui.restore(panel, selected) end
  panel.lines = next_lines
end

local function stop_timer(target)
  if target.timer then target.timer:stop(); target.timer:close(); target.timer = nil end
end

local function sync_timer()
  if not panel then return end
  if panel.page ~= PAGES.translations and panel.page ~= PAGES.missing then stop_timer(panel); return end
  if panel.timer then return end
  panel.timer = vim.uv.new_timer()
  panel.timer:start(500, 500, vim.schedule_wrap(function()
    if panel and (panel.page == PAGES.translations or panel.page == PAGES.missing) then M.render() end
  end))
end

function M.close()
  if not panel then return end
  local old = panel
  panel = nil
  stop_timer(old)
  pcall(vim.api.nvim_del_augroup_by_id, old.group)
  if vim.api.nvim_win_is_valid(old.win) then pcall(vim.api.nvim_win_close, old.win, true) end
  if vim.api.nvim_buf_is_valid(old.buf) then pcall(vim.api.nvim_buf_delete, old.buf, { force = true }) end
end

local pack_keys = { '<CR>', '/', 'i', 'u', 'U', 'r', 'a', 'j', 'k', '<Down>', '<Up>' }

local function use_page(index)
  local buf = panel.buf
  if panel.page == PAGES.overview then pcall(vim.keymap.del, 'n', '<CR>', { buffer = buf }) end
  if panel.page == PAGES.packs then
    panel.pack_selection = require('nvim-zh.packs_ui').selection(panel) or panel.pack_selection
    for _, key in ipairs(pack_keys) do pcall(vim.keymap.del, 'n', key, { buffer = buf }) end
    panel.pack_items = nil
  end
  panel.page, panel.lines = index, nil
  vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
  if index == PAGES.packs then
    local ui = require('nvim-zh.packs_ui')
    local instance = panel
    for _, key in ipairs(pack_keys) do
      vim.keymap.set('n', key, function()
        if panel ~= instance then return end
        if key == 'j' or key == '<Down>' then ui.move(panel, 1); M.render()
        elseif key == 'k' or key == '<Up>' then ui.move(panel, -1); M.render()
        else ui.key(panel, key, M.render) end
      end, { buffer = buf, silent = true })
    end
  elseif index == PAGES.overview then
    vim.keymap.set('n', '<CR>', function()
      if panel and vim.api.nvim_win_get_cursor(panel.win)[1] == panel.pack_overview then use_page(PAGES.packs) end
    end, { buffer = buf, silent = true })
  end
  sync_timer()
  if index == PAGES.health then require('nvim-zh.health').run(M.render) end
  M.render()
end

function M.open(requested)
  if #vim.api.nvim_list_uis() == 0 then return nil, '当前会话没有 UI；请使用 status()/stats()/check() 查询。' end
  if panel and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_set_current_win(panel.win)
    if requested and PAGES[requested] ~= panel.page then use_page(assert(PAGES[requested])) end
    return panel.win
  end
  M.close()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, size())
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'wipe', false
  vim.bo[buf].filetype = 'nvim-zh'
  vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
  vim.wo[win].cursorline = true
  panel = { buf = buf, win = win, group = vim.api.nvim_create_augroup('NvimZhPanel', { clear = true }) }
  local function page(delta)
    if not panel then return end
    use_page((panel.page - 1 + delta) % #names + 1)
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do vim.keymap.set('n', key, M.close, { buffer = buf, silent = true }) end
  vim.keymap.set('n', '<Tab>', function() page(1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<S-Tab>', function() page(-1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '?', function()
    vim.cmd(panel and panel.page == PAGES.packs and 'help nvim-zh-packs' or 'help nvim-zh')
  end, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd({ 'VimResized', 'ColorScheme' }, { group = panel.group, callback = function()
    if panel and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, size()); M.render() end
  end })
  vim.api.nvim_create_autocmd('User', { group = panel.group, pattern = 'NvimZhChanged', callback = M.render })
  vim.api.nvim_create_autocmd('WinClosed', { group = panel.group, pattern = tostring(win), callback = M.close })
  vim.api.nvim_create_autocmd('BufWipeout', { group = panel.group, buffer = buf, callback = M.close })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = panel.group, callback = M.close })
  use_page(requested and assert(PAGES[requested]) or PAGES.overview)
  return win
end
return M
