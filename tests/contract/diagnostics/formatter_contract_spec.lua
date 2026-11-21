local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local adapter = require('nvim-zh.diagnostics')
local function setup(opts)
  require('nvim-zh').setup({ modules = {
    core = { enabled = false }, help = { enabled = false },
    ui = { notify = false, prompts = false }, plugins = { auto = false },
    lsp = { messages = false, progress = false }, diagnostics = opts,
  } })
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'example' })
local ns = h.client(buf)
local diagnostic = { lnum = 0, col = 0, source = 'clangd', code = 'redefinition', message = "Redefinition of 'x'" }
local function rendered_lines()
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      local chunks = {}
      for _, chunk in ipairs(line) do table.insert(chunks, chunk[1]) end
      table.insert(result, table.concat(chunks))
    end
  end
  return table.concat(result, '\n')
end
local function float_text()
  local float_buf, float_win = vim.diagnostic.open_float({ namespace = ns, scope = 'buffer' })
  local text = float_buf and table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), '\n') or nil
  if float_win then vim.api.nvim_win_close(float_win, true) end
  return text
end

-- nil is the public diagnostic filtering contract for all three displays.
local hide = function() return nil end
vim.diagnostic.config({ virtual_text = { format = hide }, virtual_lines = { format = hide }, float = { format = hide } })
vim.diagnostic.set(ns, buf, { diagnostic })
local snapshot = vim.deepcopy(diagnostic)
local baseline_float = float_text()
setup({ enabled = true })
equal(vim.diagnostic.config().virtual_text.format(diagnostic), nil, 'virtual_text revived a filtered diagnostic')
equal(vim.diagnostic.config().virtual_lines.format(diagnostic), nil, 'virtual_lines revived a filtered diagnostic')
equal(rendered_lines(), '', 'filtered diagnostic acquired virtual lines')
equal(float_text(), baseline_float, 'float changed filtered diagnostic rendering')
check(vim.deep_equal(diagnostic, snapshot), 'formatter mutated input diagnostic')
adapter.teardown()
vim.diagnostic.reset(ns, buf)

-- Compare real extmarks with Neovim's default formatter, including an unknown server.
for _, source in ipairs({ 'other-server', 'clangd' }) do
  vim.diagnostic.config({ virtual_text = false, virtual_lines = true, float = false })
  local item = vim.deepcopy(diagnostic)
  item.source, item.code = source, 'E123'
  vim.diagnostic.set(ns, buf, { item })
  local baseline = rendered_lines()
  check(baseline:find('E123: ', 1, true), 'baseline lacks diagnostic code')
  setup({ enabled = true })
  local expected = source == 'clangd' and baseline:gsub("Redefinition of 'x'", "'x' 重复定义") or baseline
  equal(rendered_lines(), expected, 'default virtual_lines changed non-message rendering')
  equal(vim.diagnostic.get(buf, { namespace = ns })[1].message, diagnostic.message, 'stored message changed')
  local formatter = vim.diagnostic.config().virtual_lines.format
  equal(formatter({ message = 'plain', source = source, code = 0 }), '0: plain', 'numeric code lost')
  equal(formatter({ message = 'plain', source = source }), 'plain', 'missing code added a prefix')
  adapter.teardown()
  vim.diagnostic.reset(ns, buf)
end

-- External wrappers may retain our formatter; both channel and module switches must apply.
vim.diagnostic.config({ virtual_text = true, virtual_lines = true, float = true })
setup({ enabled = true })
local originals = {}
for _, name in ipairs({ 'virtual_text', 'virtual_lines' }) do
  local ours = vim.diagnostic.config()[name].format
  originals[name] = function(d) return ours(d) end
  vim.diagnostic.config({ [name] = { format = originals[name] } })
end
setup({ enabled = true, virtual_text = false, virtual_lines = false })
equal(originals.virtual_text(diagnostic), diagnostic.message, 'disabled virtual_text still translated')
equal(originals.virtual_lines(diagnostic), 'redefinition: ' .. diagnostic.message, 'disabled virtual_lines changed baseline')
setup({ enabled = false })
equal(vim.diagnostic.config().virtual_text.format, originals.virtual_text, 'disable overwrote external formatter')
equal(originals.virtual_text(diagnostic), diagnostic.message, 'disabled module still translated')
adapter.teardown()
equal(originals.virtual_text(diagnostic), diagnostic.message, 'teardown left retained formatter active')
setup({ enabled = true, virtual_text = true, virtual_lines = true })
for _, name in ipairs({ 'virtual_text', 'virtual_lines' }) do
  equal(vim.diagnostic.config()[name].format, originals[name], 'teardown/re-enable reclaimed external formatter')
  equal(adapter.info()[name].reason, 'external_override', 'external formatter ownership forgotten')
end
adapter.teardown()
vim.api.nvim_buf_delete(buf, { force = true })
print('FORMATTER_CONTRACT_SPEC=PASS nil_filter default_code retained_callbacks raw_data')
