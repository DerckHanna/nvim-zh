local M = {}
function M.check(value, message) if not value then error(message, 2) end end
function M.equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end
function M.pack(...) return { n = select('#', ...), ... } end
function M.overrides()
  return {
    ['which-key'] = { desc = {
      Delete = '删除',
      Open = '打开',
    } },
    telescope = { title = {
      ['Find Files'] = '查找文件',
      Help = '帮助',
      Results = '结果',
      Prompt = '提示',
      ['File Preview'] = '文件预览',
    } },
    ['nvim-tree'] = { mapping = {
      Open = '打开',
    } },
  }
end
function M.empty_catalogs()
  local sources = {}
  for _, domain in ipairs({ 'nvim-zh', 'nvim-ui', 'which-key', 'telescope', 'nvim-tree', 'clangd' }) do
    sources[domain] = { schema = 1, domain = domain, locale = 'zh_CN', entries = {} }
  end
  return sources
end
function M.setup(plugins, overrides)
  require('nvim-zh').setup({
    modules = {
      core = { enabled = false },
      ui = { notify = false, prompts = false, echo = false },
      plugins = plugins or { auto = true, disabled = {} },
    },
    overrides = overrides or M.overrides(),
    missing = { enabled = true, max_entries = 64 },
  })
end
return M
