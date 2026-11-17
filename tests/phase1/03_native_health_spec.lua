local function check(value, message)
  if not value then error(message, 2) end
end
local native = require('nvim-zh.native')
local info = native.info()
check(type(info.progpath) == 'string' and info.progpath ~= '', 'missing progpath')
check(info.mo_path:find('share/locale/zh_CN.UTF-8/LC_MESSAGES/nvim.mo', 1, true) ~= nil, 'unexpected MO path')
check(type(info.mo_exists) == 'boolean', 'missing MO existence state')
local before = { lang = vim.v.lang, lc_all = vim.env.LC_ALL, lc_messages = vim.env.LC_MESSAGES, helplang = vim.o.helplang }
local results = native.check()
check(#results >= 3, 'native check is incomplete')
local names = {}
for _, result in ipairs(results) do names[result.name] = result.status end
check(names['core.command'] ~= nil, 'language command was not checked')
check(names['core.catalog'] == 'ok' or names['core.catalog'] == 'warn', 'catalog check missing')
check(names['core.locale'] ~= nil, 'locale check missing')
check(vim.v.lang == before.lang and vim.env.LC_ALL == before.lc_all and vim.env.LC_MESSAGES == before.lc_messages, 'native check mutated locale')
check(vim.o.helplang == before.helplang, 'native check mutated helplang')
local all = require('nvim-zh.health').collect()
local found_core = false
for _, result in ipairs(all) do if result.name:find('^core%.') then found_core = true end end
check(found_core, 'aggregate health omitted core results')
vim.cmd('checkhealth nvim-zh')
local report = ''
-- Nightly checkhealth fills its buffer asynchronously; 0.10-0.12 are already complete.
vim.wait(2000, function()
  report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  return report:find('nvim-zh', 1, true) ~= nil and report:find('core.', 1, true) ~= nil
end, 10)
check(report:find('nvim-zh', 1, true) ~= nil and report:find('core.', 1, true) ~= nil, 'checkhealth report missing core details')
print('NATIVE_HEALTH_SPEC=PASS current_core_status=' .. tostring(names['core.messages']))
