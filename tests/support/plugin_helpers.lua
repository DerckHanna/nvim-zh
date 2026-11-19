local M = {}

local telescope_source = vim.env.NVIM_ZH_TEST_TELESCOPE
if telescope_source then
  require('nvim-zh').register_adapter_source('telescope', telescope_source)
else
  -- Adapter fixtures supply in-memory modules. Real source and generation
  -- proof is exercised separately by the upstream and TUI suites.
  local evidence = require('nvim-zh.adapters.evidence')
  local verify = evidence.verify
  evidence.verify = function(id, ...)
    if id == 'telescope' then return { kind = 'fixture' } end
    return verify(id, ...)
  end
end

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
  for _, domain in ipairs({ 'nvim-zh', 'nvim-ui', 'which-key', 'telescope', 'nvim-tree', 'nvim-dap', 'nvim-dap-ui', 'nvim-dap-view', 'clangd' }) do
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
