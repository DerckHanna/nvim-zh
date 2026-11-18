local function check(value, message)
  if not value then error(message, 2) end
end
local zh = require('nvim-zh')
vim.o.helplang = 'de,it'
zh.setup()
check(vim.o.helplang == 'cn,de,it,en', 'unexpected helplang merge: ' .. vim.o.helplang)
zh.setup()
check(vim.o.helplang == 'cn,de,it,en', 'setup is not idempotent')
check(zh.status().configured == true, 'setup did not update state')
check(zh.status().config.modules.core.apply_language == true, 'default setup must enable automatic native integration')
zh.setup({ modules = { core = { apply_language = false } } })
check(zh.status().config.modules.core.apply_language == false, 'explicit legacy opt-out was ignored')
vim.o.helplang = 'de'
zh.setup({ modules = { help = { enabled = false } } })
check(vim.o.helplang == 'de', 'disabled help module changed helplang')
check(not pcall(zh.setup, false), 'non-table false config was accepted')
local ok = pcall(zh.setup, { modules = { help = { enabled = 'invalid' } } })
check(not ok, 'invalid config was accepted')
check(vim.o.helplang == 'de', 'invalid setup caused side effects')
print('SETUP_SPEC=PASS')
