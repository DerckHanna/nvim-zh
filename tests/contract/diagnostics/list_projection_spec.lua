-- Edge cases of the quickfix/location-list projection: the displayed text may
-- change, while the list entries, their order, selection and external
-- ownership must stay exactly what Neovim produced.
local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local check, equal = h.check, h.equal
local known = "Redefinition of 'x'"
local shown = "'x' 重复定义"
local original_setqflist = vim.diagnostic.setqflist

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'int x; int x; int y;', 'second line' })
local ns_a = vim.api.nvim_create_namespace('nvim-zh-list-a')
local ns_b = vim.api.nvim_create_namespace('nvim-zh-list-b')

local function item(extra)
  return vim.tbl_extend('force', {
    bufnr = buf, lnum = 0, end_lnum = 0, col = 4, end_col = 5, severity = vim.diagnostic.severity.ERROR,
    message = known, source = 'clangd', code = 'redefinition',
    user_data = { lsp = { message = known, data = { id = 7 } } },
  }, extra or {})
end

local function qf_all()
  local list = vim.fn.getqflist({ id = 0, items = 1, idx = 0, title = 1, context = 1 })
  return { items = list.items, idx = list.idx, title = list.title, context = list.context }
end

local function line(index)
  vim.cmd.copen()
  local text = vim.api.nvim_buf_get_lines(0, index - 1, index, false)[1]
  vim.cmd.cclose()
  return text
end

-- Configuration is committed asynchronously; wait for a settled state and
-- prepare the (deferred) clangd domain before inspecting displays.
local function settle(enabled)
  assert(vim.wait(10000, function()
    local runtime = require('nvim-zh').status().runtime
    return runtime.status ~= 'syncing' and require('nvim-zh.diagnostics').info().enabled == enabled
  end, 10), 'diagnostics configuration did not settle')
  if enabled then require('nvim-zh.packs').prepare_domain('clangd') end
end

local function populate(diagnostics)
  vim.diagnostic.reset(ns_a, buf)
  vim.diagnostic.reset(ns_b, buf)
  for ns, list in pairs(diagnostics) do vim.diagnostic.set(ns, buf, list) end
end

-- Baseline: no projection installed.
h.setup({ enabled = false })
settle(false)
local user_calls = 0
local function user_format(d) user_calls = user_calls + 1; return d.message end
populate({ [ns_a] = { item(), item({ lnum = 1, col = 0, end_col = 2, message = 'Previous definition is here', code = 'previous_definition' }) } })
vim.diagnostic.setqflist({ open = false, format = user_format, title = 'baseline' })
local baseline = qf_all()
equal(#baseline.items, 2, 'baseline list size')
equal(user_calls, 2, 'baseline user formatter calls')

h.setup()
settle(true)

-- 1. Same list, mixed sources: only clangd rows are projected. Raw entries,
-- order, selection, titles and user_data match the unprojected baseline.
populate({ [ns_a] = { item(), item({ lnum = 1, col = 0, end_col = 2, message = 'Previous definition is here', code = 'previous_definition' }) } })
user_calls = 0
vim.diagnostic.setqflist({ open = false, format = user_format, title = 'baseline' })
equal(user_calls, 2, 'projected list changed formatter call count')
local projected = qf_all()
check(vim.deep_equal(projected, baseline), 'projection changed raw quickfix entries')
equal(line(1):find(shown, 1, true) ~= nil, true, 'clangd row not displayed in Chinese')
equal(line(2):find('此前的定义在这里', 1, true) ~= nil, true, 'second row not displayed in Chinese')
equal(require('nvim-zh').raw().raw_text, known, 'raw() returned translated text')

-- 2. Unknown source stays unprojected beside a translated row.
populate({ [ns_a] = { item(), item({ lnum = 1, col = 0, source = 'other-server' }) } })
vim.diagnostic.setqflist({ open = false, title = 'mixed' })
equal(line(1):find(shown, 1, true) ~= nil, true, 'known source row lost projection')
equal(line(2):find(known, 1, true) ~= nil and not line(2):find('重复定义', 1, true), true,
  'unknown source row was translated')
equal(vim.fn.getqflist()[2].text, known, 'unknown source raw text changed')

-- 3. Two clients (namespaces) publishing the same text at the same place are
-- an ambiguous source; those rows fall back while unrelated rows are kept.
populate({ [ns_a] = { item(), item({ col = 8, end_col = 9, lnum = 0 }) }, [ns_b] = { item() } })
vim.diagnostic.setqflist({ open = false, title = 'two-clients' })
local rows = vim.fn.getqflist()
equal(#rows, 3, 'two-client list lost an entry')
local translated, source = 0, 0
for i = 1, #rows do
  local rendered = line(i)
  if rendered:find('重复定义', 1, true) then translated = translated + 1 end
  if rendered:find(known, 1, true) then source = source + 1 end
  equal(rows[i].text, known, 'two-client raw text changed')
end
equal(translated, 1, 'only the unambiguous row may be projected')
equal(source, 2, 'ambiguous rows must fall back to source text')

-- 4. A user formatter that rewrites the message owns the display.
populate({ [ns_a] = { item() } })
vim.diagnostic.setqflist({ open = false, title = 'rewritten', format = function(d) return 'custom: ' .. d.message end })
equal(vim.fn.getqflist()[1].text, 'custom: ' .. known, 'user rewritten text lost')
equal(line(1):find('custom: ' .. known, 1, true) ~= nil, true, 'user rewritten display was replaced')

-- 5. A formatter that filters rows keeps Neovim's remaining order and
-- the projection still lines up with the surviving row.
populate({ [ns_a] = { item({ code = 'drop', col = 0, end_col = 1 }), item() } })
vim.diagnostic.setqflist({ open = false, title = 'filtered', format = function(d)
  if d.code == 'drop' then return nil end
  return d.message
end })
equal(#vim.fn.getqflist(), 1, 'filtered row survived')
equal(line(1):find(shown, 1, true) ~= nil, true, 'surviving row not projected')

-- 6. Appending to an installed list invalidates its records instead of
-- applying them to the wrong rows.
populate({ [ns_a] = { item() } })
vim.diagnostic.setqflist({ open = false, title = 'stale' })
local id = vim.fn.getqflist({ id = 0 }).id
vim.fn.setqflist({}, 'a', { id = id, items = { { bufnr = buf, lnum = 2, text = known } } })
local after = vim.fn.getqflist({ id = id, items = 1 }).items
equal(#after, 2, 'append lost an entry')
equal(after[1].text, known, 'append changed existing raw text')
equal(line(2):find('重复定义', 1, true), nil, 'stale record decorated a foreign row')
equal(require('nvim-zh').raw().raw_text, known, 'raw() after append')

-- 7. Location lists are independent per window.
local win_a = vim.api.nvim_get_current_win()
vim.cmd('botright split')
local win_b = vim.api.nvim_get_current_win()
populate({ [ns_a] = { item() } })
vim.diagnostic.setloclist({ winnr = win_a, open = false, title = 'loc-a' })
vim.diagnostic.setloclist({ winnr = win_b, open = false, title = 'loc-b', format = function() return 'only b' end })
equal(vim.fn.getloclist(win_a)[1].text, known, 'window A raw text changed')
equal(vim.fn.getloclist(win_b)[1].text, 'only b', 'window B user text lost')
vim.api.nvim_set_current_win(win_a)
vim.cmd.lopen()
equal(vim.api.nvim_get_current_line():find(shown, 1, true) ~= nil, true, 'window A location list not projected')
vim.cmd.lclose()
vim.api.nvim_set_current_win(win_b)
vim.cmd.lopen()
equal(vim.api.nvim_get_current_line():find('only b', 1, true) ~= nil, true, 'window B location list was replaced')
vim.cmd.lclose()
vim.api.nvim_win_close(win_b, true)

-- 8. Disabling clears only our formatters and leaves foreign ones.
local foreign = function() return { 'foreign' } end
populate({ [ns_a] = { item() } })
vim.diagnostic.setqflist({ open = false, title = 'ours' })
local ours_id = vim.fn.getqflist({ id = 0 }).id
vim.fn.setqflist({}, ' ', { title = 'foreign', quickfixtextfunc = foreign })
local foreign_id = vim.fn.getqflist({ id = 0 }).id
h.setup({ enabled = false })
settle(false)
equal(vim.fn.getqflist({ id = ours_id, quickfixtextfunc = 1 }).quickfixtextfunc, '', 'our formatter outlived teardown')
check(rawequal(vim.fn.getqflist({ id = foreign_id, quickfixtextfunc = 1 }).quickfixtextfunc, foreign),
  'foreign formatter removed')
equal(vim.diagnostic.setqflist, original_setqflist, 'setqflist not restored')

require('nvim-zh.diagnostics').teardown()
vim.api.nvim_buf_delete(buf, { force = true })
print('DIAGNOSTIC_LIST_PROJECTION_SPEC=PASS mixed_sources ambiguous_clients user_rewrite filter stale loclist_windows ownership')
