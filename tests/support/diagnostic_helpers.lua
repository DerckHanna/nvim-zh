local M = {}
function M.check(value, message) if not value then error(message, 2) end end
function M.equal(actual, expected, message)
  if actual ~= expected then error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2) end
end
function M.pack(...) return { n = select('#', ...), ... } end
function M.setup(diagnostics, lsp)
  require('nvim-zh').setup({
    modules = {
      core = { enabled = false },
      ui = { notify = false, prompts = false, echo = false },
      plugins = { auto = false },
      diagnostics = diagnostics or { enabled = true, virtual_text = true, virtual_lines = true, float = true },
      lsp = lsp or { messages = true, progress = true },
    },
    missing = { enabled = true, max_entries = 128 },
  })
end
return M
