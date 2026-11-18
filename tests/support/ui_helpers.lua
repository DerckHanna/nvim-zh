local M = {}

function M.check(value, message)
  if not value then error(message, 2) end
end

function M.equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.pack(...)
  return { n = select('#', ...), ... }
end

function M.ui_overrides()
  return {
    ['nvim-ui'] = {
      [''] = {
        Ready = '就绪',
        Done = '完成',
        Input = '输入',
        ['Input:'] = '输入：',
        ['Select one of:'] = '请选择：',
        ['Prompt title'] = '提示标题',
        ['Loaded %s'] = '已加载 %s',
        ['Opened {name}'] = '已打开 {name}',
      },
      echo = {
        ['Echo ready'] = '回显就绪',
      },
      select_item = {
        Ready = '选项就绪',
      },
    },
  }
end

function M.setup(ui, overrides)
  require('nvim-zh').setup({
    modules = { ui = ui or { notify = false, prompts = false, echo = false } },
    overrides = overrides or M.ui_overrides(),
    missing = { enabled = true, max_entries = 64 },
  })
end

return M
