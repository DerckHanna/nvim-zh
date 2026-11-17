local M = {}
local state = { configured = false, config = require('nvim-zh.config').resolve() }

function M.setup(opts)
  local config = require('nvim-zh.config').resolve(opts)
  local catalog = require('nvim-zh.catalog')
  if not catalog.is_registered('nvim-zh') then
    catalog._register_builtin('nvim-zh', { locale = 'zh_CN', source = 'translations/po/zh_CN/nvim-zh.po' })
  end
  if not catalog.is_registered('nvim-ui') then
    catalog._register_builtin('nvim-ui', { locale = 'zh_CN', source = 'translations/po/zh_CN/nvim-ui.po' })
  end
  if not catalog.is_registered('which-key') then
    catalog._register_builtin('which-key', { locale = 'zh_CN', source = 'translations/po/zh_CN/which-key.po' })
  end
  if not catalog.is_registered('telescope') then
    catalog._register_builtin('telescope', { locale = 'zh_CN', source = 'translations/po/zh_CN/telescope.po' })
  end
  if not catalog.is_registered('nvim-tree') then
    catalog._register_builtin('nvim-tree', { locale = 'zh_CN', source = 'translations/po/zh_CN/nvim-tree.po' })
  end
  if not catalog.is_registered('clangd') then
    catalog._register_builtin('clangd', { locale = 'zh_CN', source = 'translations/po/zh_CN/clangd.po' })
  end
  require('nvim-zh.engine').setup(config)
  require('nvim-zh.help').setup(config.modules.help)
  require('nvim-zh.ui').setup(config.modules.ui)
  require('nvim-zh.plugins').setup(config.modules.plugins)
  require('nvim-zh.diagnostics').setup(config.modules.diagnostics)
  require('nvim-zh.lsp').setup(config.modules.lsp)
  state = { configured = true, config = config }
  return M
end

function M.info()
  return {
    configured = state.configured,
    config = vim.deepcopy(state.config),
    help = require('nvim-zh.help').info(state.config.modules.help),
    native = require('nvim-zh.native').info(),
    ui = require('nvim-zh.ui').info(),
    plugins = require('nvim-zh.plugins').info(),
    diagnostics = require('nvim-zh.diagnostics').info(),
    lsp = require('nvim-zh.lsp').info(),
    v_lang = vim.v.lang,
    helplang = vim.o.helplang,
    nvim_version = tostring(vim.version()),
  }
end

function M.show_info()
  local info = M.info()
  vim.notify(table.concat({
    'nvim-zh 阶段 8：真实使用界面与 Help 文档翻译扩展',
    'Neovim: ' .. info.nvim_version,
    'setup: ' .. tostring(info.configured),
    'v:lang: ' .. info.v_lang,
    'helplang: ' .. info.helplang,
    '核心 MO: ' .. info.native.mo_path .. ' (' .. tostring(info.native.mo_exists) .. ')',
    '中文帮助: ' .. info.help.chinese_help,
    ('UI notify: active=%s reason=%s'):format(tostring(info.ui.notify.active), tostring(info.ui.notify.reason)),
    ('UI input/select: active=%s/%s'):format(tostring(info.ui.input.active), tostring(info.ui.select.active)),
    ('UI echo: enabled=%s active=%s reason=%s'):format(
      tostring(info.ui.echo.enabled), tostring(info.ui.echo.active), tostring(info.ui.echo.reason)),
    ('Plugin which-key: active=%s reason=%s'):format(
      tostring(info.plugins['which-key'].active), tostring(info.plugins['which-key'].reason)),
    ('Plugin telescope: active=%s dynamic=%s reason=%s'):format(
      tostring(info.plugins.telescope.active), tostring(info.plugins.telescope.dynamic_active), tostring(info.plugins.telescope.reason)),
    ('Plugin nvim-tree: active=%s reason=%s'):format(
      tostring(info.plugins['nvim-tree'].active), tostring(info.plugins['nvim-tree'].reason)),
    ('Diagnostics clangd: vt=%s vl=%s float=%s static=%s corpus=%s/%s runtime=%s/%s'):format(
      tostring(info.diagnostics.virtual_text.active), tostring(info.diagnostics.virtual_lines.active), tostring(info.diagnostics.float.active),
      tostring(info.diagnostics.static_entries), tostring(info.diagnostics.corpus_translated), tostring(info.diagnostics.corpus_entries),
      tostring(info.diagnostics.runtime_translated), tostring(info.diagnostics.runtime_observed)),
    ('LSP clangd: messages=%s progress=%s logMessage=source'):format(
      tostring(info.lsp.messages), tostring(info.lsp.progress)),
  }, '\n'), vim.log.levels.INFO)
end

function M.translate(spec)
  return require('nvim-zh.engine').translate(spec)
end

function M.register_catalog(domain, loader, metadata)
  return require('nvim-zh.catalog').register(domain, loader, metadata)
end

function M.stats()
  return require('nvim-zh.engine').stats()
end

function M.reload()
  local count = require('nvim-zh.engine').reload()
  if state.configured then
    require('nvim-zh.ui').reload(state.config.modules.ui)
    require('nvim-zh.plugins').reload(state.config.modules.plugins)
    require('nvim-zh.diagnostics').reload(state.config.modules.diagnostics)
    require('nvim-zh.lsp').reload(state.config.modules.lsp)
  end
  return count
end

function M.show_missing()
  local stats = M.stats()
  local rows = require('nvim-zh.missing').list()
  local lines = {
    ('本地缺失：%d unique / %d occurrences'):format(stats.missing.unique, stats.missing.occurrences),
    ('运行时观察：%d translated / %d observed（非全 Neovim 覆盖率）'):format(stats.runtime.translated, stats.runtime.observed),
  }
  for _, domain in ipairs(stats.static.domains) do
    table.insert(lines, ('静态目录 %s: %d/%d'):format(domain.domain, domain.translated, domain.total))
  end
  for _, row in ipairs(rows) do
    table.insert(lines, ('[%s/%s] %s (%d)'):format(row.domain, row.context, row.msgid, row.count))
  end
  if #rows == 0 then table.insert(lines, '没有观察到缺失翻译') end
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
  return rows
end

return M
