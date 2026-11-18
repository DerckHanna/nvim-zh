local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local calls = {}
local throw_original = false
local recurse = false
local notify_spy = function(msg, level, opts)
  table.insert(calls, { msg = msg, level = level, opts = opts })
  if recurse then
    recurse = false
    vim.notify(msg, level, opts)
  end
  if throw_original then error('original-notify-error') end
  return 'notify-return', 42
end
vim.notify = notify_spy
local original_once = vim.notify_once
h.setup({ notify = true, prompts = false, echo = false })
check(vim.notify ~= notify_spy, 'notify was not wrapped')
check(vim.notify_once ~= original_once, 'notify_once lifecycle wrapper was not installed')
local notify_wrapper = vim.notify
local once_wrapper = vim.notify_once
h.setup({ notify = true, prompts = false, echo = false })
check(vim.notify == notify_wrapper and vim.notify_once == once_wrapper, 'repeated setup stacked notify wrappers')

local opts = { title = 'unchanged', data = { value = 1 } }
local returns = pack(vim.notify('Ready', vim.log.levels.WARN, opts))
equal(returns.n, 2, 'notify return arity')
equal(returns[1], 'notify-return', 'notify first return')
equal(returns[2], 42, 'notify second return')
equal(calls[#calls].msg, '就绪', 'exact notify translation')
check(calls[#calls].level == vim.log.levels.WARN and calls[#calls].opts == opts, 'notify level/opts identity changed')

vim.notify('Loaded init.lua', vim.log.levels.INFO, opts)
equal(calls[#calls].msg, '已加载 init.lua', 'formatted printf template')
vim.notify('Opened 项目.lua')
equal(calls[#calls].msg, '已打开 项目.lua', 'formatted named template')
vim.notify('Unknown 通知\nsecond line')
equal(calls[#calls].msg, 'Unknown 通知\nsecond line', 'unknown notify fallback')

local before = #calls
equal(vim.notify_once('Ready'), true, 'first notify_once result')
equal(vim.notify_once('Ready'), false, 'source notify_once dedup')
equal(vim.notify_once('Done'), true, 'distinct source must not share dedup key')
equal(vim.notify_once('Loaded one.lua'), true, 'first dynamic source')
equal(vim.notify_once('Loaded two.lua'), true, 'dynamic values must not collapse dedup')
equal(vim.notify_once('Loaded one.lua'), false, 'dynamic source repeat dedup')
equal(#calls, before + 4, 'notify_once display count')
equal(calls[#calls].msg, '已加载 two.lua', 'notify_once dynamic translation')

recurse = true
before = #calls
vim.notify('Ready')
recurse = false
equal(#calls - before, 2, 'recursive original notification should call through once')
equal(calls[#calls].msg, '就绪', 'recursive notification changed text')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('translation exploded') end
before = #calls
vim.notify('Ready', vim.log.levels.ERROR, opts)
equal(calls[#calls].msg, 'Ready', 'translation exception did not fall back')
equal(#calls, before + 1, 'translation error emitted recursive/internal notifications')
engine.translate = original_translate

throw_original = true
local ok, err = pcall(vim.notify, 'Ready')
throw_original = false
check(not ok and tostring(err):find('original-notify-error', 1, true), 'original notify exception was swallowed')

h.setup({ notify = false, prompts = false, echo = false })
check(vim.notify == notify_spy and vim.notify_once == original_once, 'disabling notify did not restore originals')
print('NOTIFY_CONTRACT_SPEC=PASS calls=' .. #calls)
