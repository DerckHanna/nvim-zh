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
  local backend = package.loaded['nvim-zh.native_backend']
  local current = backend and backend.info() or { active = false, status = 'idle' }
  mo_path = current.mo_path or mo_path
  return vim.tbl_extend('force', current, {
    progpath = realpath,
    mo_path = mo_path,
    mo_exists = stat(mo_path) ~= nil,
    v_lang = vim.v.lang,
    lc_all = vim.env.LC_ALL,
    lc_messages = vim.env.LC_MESSAGES,
  })
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

  local available = info.active or normalize_locale(info.v_lang or ''):find('^zhcn') ~= nil
  table.insert(results, {
    name = 'core.locale',
    status = available and 'ok' or 'warn',
    message = available and '当前进程已选择中文消息语言'
      or ('中文消息语言未启用：' .. tostring(info.reason or info.status)),
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
      or ('核心消息当前未启用中文（v:lang=' .. tostring(info.v_lang) .. '）：' .. tostring(info.reason or info.status)),
  })
  return results
end

return M
