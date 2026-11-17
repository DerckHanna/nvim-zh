local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal
local pickers = { new = function(opts) return opts end }
package.loaded['telescope.pickers'] = pickers
local calls = {}
local previewer = {}
function previewer:title(entry, dynamic)
  table.insert(calls, { self = self, entry = entry, dynamic = dynamic })
  if dynamic then return entry and entry.dynamic_title end
  return self.static_title
end
package.loaded['telescope.previewers.previewer'] = previewer
local original_title = previewer.title
h.setup()
local entry = { dynamic_title = 'Find Files', payload = { unchanged = true } }
previewer.static_title = 'Help Tags'
equal(previewer:title(entry, false), '帮助标签', 'static previewer title not translated')
equal(previewer:title(entry, true), '查找文件', 'dynamic previewer title not translated')
entry.dynamic_title = 'Unknown title'
equal(previewer:title(entry, true), 'Unknown title', 'unknown dynamic title changed')
entry.dynamic_title = false
equal(previewer:title(entry, true), false, 'false dynamic title changed')
entry.dynamic_title = nil
equal(previewer:title(entry, true), nil, 'nil dynamic title changed')
equal(calls[1].entry, entry, 'previewer entry identity changed')
check(calls[1].self == previewer, 'previewer self identity changed')
local wrapped = previewer.title
check(wrapped ~= original_title, 'previewer wrapper missing')
h.setup()
equal(previewer.title, wrapped, 'repeated setup replaced the owned previewer wrapper')
h.setup({ auto = true, disabled = { 'telescope' } })
equal(previewer.title, original_title, 'Telescope disable did not restore previewer title')
h.setup()
previewer.title = function() return 'External Title' end
require('nvim-zh').reload()
equal(previewer:title(entry, true), 'External Title', 'reload reclaimed external previewer title')
require('nvim-zh.plugins').teardown()
equal(previewer:title(entry, true), 'External Title', 'teardown reclaimed external previewer title')
print('TELESCOPE_DYNAMIC_SPEC=PASS static,dynamic false_nil_fallback entry_identity')
