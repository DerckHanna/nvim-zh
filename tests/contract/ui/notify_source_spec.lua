local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal
local calls = {}
vim.notify = function(msg, level, opts)
  calls[#calls + 1] = { msg = msg, level = level, opts = opts }
end
h.setup({ notify = true, prompts = false, echo = false }, {
  ['demo-plugin'] = { notification = { Empty = '空' } },
})
local ui = require('nvim-zh.ui')
local before_sources = require('nvim-zh').status().ui.sources
local release = ui.register_source({
  title = 'Demo', domain = 'demo-plugin', context = 'notification', prefix = '[Demo]',
})
check(not pcall(ui.register_source, { title = 'Demo', domain = 'other' }), 'duplicate source title accepted')
local opts = { title = 'Demo', marker = calls }
local observed = require('nvim-zh').stats().runtime.observed
vim.notify('[Demo] Empty', vim.log.levels.WARN, opts)
equal(calls[1].msg, '[Demo] 空', 'source prefix or translation changed')
check(calls[1].opts == opts and calls[1].level == vim.log.levels.WARN, 'notify options/level changed')
equal(require('nvim-zh').stats().runtime.observed - observed, 1, 'notification was observed/translated more than once')
vim.notify('[Demo]\nEmpty', nil, { title = 'Demo' })
equal(calls[2].msg, '[Demo]\n空', 'multiline prefix whitespace changed')
vim.notify('Empty', nil, { title = 'Demo' })
equal(calls[3].msg, '空', 'title-capable notification was not translated')
vim.notify('Unknown', nil, { title = 'Demo' })
equal(calls[4].msg, 'Unknown', 'unknown source text did not fall back')
vim.notify('Empty', nil, { title = 'Other' })
equal(calls[5].msg, 'Empty', 'unrelated title was assigned to plugin domain')
local sources = require('nvim-zh').status().ui.sources
equal(#sources, #before_sources + 1, 'registered source missing from status')
local demo
for _, source in ipairs(sources) do if source.title == 'Demo' then demo = source end end
check(demo ~= nil, 'registered title missing from status')
equal(demo.domain, 'demo-plugin', 'wrong source domain in status')
equal(demo.context, 'notification', 'wrong source context in status')
release(); release()
check(vim.deep_equal(require('nvim-zh').status().ui.sources, before_sources), 'release altered other sources')
vim.notify('[Demo] Empty', nil, { title = 'Demo' })
equal(calls[6].msg, '[Demo] Empty', 'released source still routes translations')
print('NOTIFY_SOURCE_SPEC=PASS exact_title prefix_preserved single_observation fallback idempotent_release')
