local M = {}
function M.check(value, message) if not value then error(message, 2) end end
function M.equal(actual, expected, message)
  if actual ~= expected then error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2) end
end
function M.setup(preserve_display)
  if not preserve_display then
    vim.diagnostic.config({ virtual_text = true, virtual_lines = true, float = true })
  end
  require('nvim-zh').setup({
    modules = {
      ui = { notify = false, prompts = false, echo = false },
      plugins = { auto = false },
      diagnostics = { enabled = true, virtual_text = true, virtual_lines = true, float = true },
      lsp = { messages = false, progress = false },
    },
    missing = { enabled = true, max_entries = 128 },
  })
end
return M
