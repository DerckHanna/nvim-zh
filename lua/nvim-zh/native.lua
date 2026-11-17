local M = {}

local function stat(path)
  return path and vim.uv.fs_stat(path) or nil
end

local function normalize_locale(locale)
  return locale:lower():gsub('[^%w]', '')
end

function M.info()
  local realpath = vim.uv.fs_realpath(vim.v.progpath) or vim.v.progpath
  local prefix = vim.fs.dirname(vim.fs.dirname(realpath))
  local mo_path = prefix .. '/share/locale/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
  return {
    progpath = realpath,
    mo_path = mo_path,
    mo_exists = stat(mo_path) ~= nil,
    v_lang = vim.v.lang,
    lc_all = vim.env.LC_ALL,
    lc_messages = vim.env.LC_MESSAGES,
  }
end

local function locale_available()
  if vim.fn.executable('locale') ~= 1 then return nil end
  local ok, process = pcall(function() return vim.system({ 'locale', '-a' }):wait() end)
  if not ok or process.code ~= 0 then return nil end
  local wanted = normalize_locale('zh_CN.UTF-8')
  for _, locale in ipairs(vim.split(process.stdout or '', '\n', { trimempty = true })) do
    if normalize_locale(vim.trim(locale)) == wanted then return true end
  end
  return false
end

function M.check()
  local info = M.info()
  local results = {}
  local command_exists = vim.fn.exists(':language') == 2
  table.insert(results, {
    name = 'core.command',
    status = command_exists and 'ok' or 'error',
    message = command_exists and ':language 可用；检查过程不会修改 locale' or ':language 不可用',
  })

  local available = locale_available()
  table.insert(results, {
    name = 'core.locale',
    status = available and 'ok' or 'warn',
    message = available == nil and '无法执行 locale -a；请手动确认 zh_CN.UTF-8'
      or available and '系统 locale zh_CN.UTF-8 可用'
      or '系统缺少 zh_CN.UTF-8；请生成 locale，并在启动前设置 LC_MESSAGES，避免 LC_ALL 覆盖',
  })
  table.insert(results, {
    name = 'core.catalog',
    status = info.mo_exists and 'ok' or 'warn',
    message = info.mo_exists and ('已找到核心中文目录：' .. info.mo_path)
      or ('未找到核心中文目录：' .. info.mo_path .. '；请安装带 zh_CN gettext 资源的 Neovim 包'),
  })

  local current = ''
  if command_exists then
    local ok, output = pcall(vim.fn.execute, 'language messages')
    current = ok and output or output
  end
  local chinese_selected = type(info.v_lang) == 'string' and info.v_lang:lower():find('^zh_cn') ~= nil
  local translated = chinese_selected and current:find('当前的', 1, true) ~= nil
  table.insert(results, {
    name = 'core.messages',
    status = translated and 'ok' or 'warn',
    message = translated and '核心消息探针已显示中文'
      or ('核心消息当前未启用中文（v:lang=' .. tostring(info.v_lang) .. '）；nvim-zh 不会自动修改 locale'),
  })
  return results
end

return M
