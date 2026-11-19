local zh = require('nvim-zh')
local adapter = require('nvim-zh.adapters.nvim_dap_view')

zh.setup({ modules = { core = { enabled = false } } })
assert(not package.loaded['dap-view'], 'the adapter loaded its target')

local views = { cleanup_view = function(_, message) return message end }
local source = string.rep('\n', 81) .. [[
local views = ...
local M = {}
M.show = function()
    return views.cleanup_view(true, "No expressions")
end
M.other = function() return views.cleanup_view(true, "No expressions") end
return M
]]
local current = true
local module = adapter.project_source('dap-view.watches.view', source, '@fixture', function() return current end)(views)
assert(module.show() == '暂无监视表达式')
assert(module.other() == 'No expressions')

local saved = module.show
module.show = function() return 'external result' end
assert(module.show() == 'external result' and saved() == 'No expressions')
module.show = saved
current = false
assert(saved() == 'No expressions')
current = true
zh.teardown()
assert(saved() == 'No expressions')
zh.setup({ modules = { core = { enabled = false } } })
assert(saved() == '暂无监视表达式')

local bad_source = source:gsub('No expressions', 'No match')
assert(not pcall(adapter.project_source, 'dap-view.watches.view', bad_source, '@fixture', function() return true end))
print('NVIM_DAP_VIEW_SPEC=PASS')
