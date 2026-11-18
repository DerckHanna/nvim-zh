local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal

local input_opts, select_opts
local throw_input, throw_select = false, false
vim.ui.input = function(opts, callback)
  input_opts = opts
  if throw_input then error('original-input-error') end
  callback(nil)
  return 'input'
end
vim.ui.select = function(items, opts, callback)
  select_opts = opts
  if throw_select then error('original-select-error') end
  callback(nil, nil)
  return 'select'
end
h.setup({ notify = false, prompts = true, select_items = false, echo = false })

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('prompt translation error') end
vim.ui.input({ prompt = 'Input:' }, function() end)
equal(input_opts.prompt, 'Input:', 'input translation exception fallback')
vim.ui.select({ 'x' }, { prompt = 'Select one of:' }, function() end)
equal(select_opts.prompt, 'Select one of:', 'select translation exception fallback')
engine.translate = original_translate

throw_input = true
local ok, err = pcall(vim.ui.input, { prompt = 'Input:' }, function() end)
throw_input = false
check(not ok and tostring(err):find('original-input-error', 1, true), 'original input exception swallowed')
throw_select = true
ok, err = pcall(vim.ui.select, { 'x' }, { prompt = 'Select one of:' }, function() end)
throw_select = false
check(not ok and tostring(err):find('original-select-error', 1, true), 'original select exception swallowed')

vim.ui.input(nil, function() end)
check(input_opts == nil, 'nil input opts changed')
vim.ui.select({ 'x' }, nil, function() end)
check(select_opts == nil, 'nil select opts changed')
print('UI_NEGATIVE_SPEC=PASS fallback=source original_errors=propagated')
