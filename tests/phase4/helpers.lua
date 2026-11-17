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
      ['Save File'] = '保存文件',
      ['Find File'] = '查找文件',
      ['Open'] = '打开',
    } },
    telescope = { title = {
      ['Find Files'] = '查找文件',
      ['Help Tags'] = '帮助标签',
      ['Git Commits'] = 'Git 提交',
    } },
  }
end
function M.setup(plugins, overrides)
  require('nvim-zh').setup({
    modules = {
      ui = { notify = false, prompts = false, echo = false },
      plugins = plugins or { auto = true, disabled = {} },
    },
    overrides = overrides or M.overrides(),
    missing = { enabled = true, max_entries = 64 },
  })
end
return M
