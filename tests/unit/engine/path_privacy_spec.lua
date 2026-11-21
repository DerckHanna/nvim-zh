local zh = require('nvim-zh')
zh.setup({ modules = { core = { enabled = false } }, missing = { enabled = true, max_entries = 16 } })
local missing = require('nvim-zh.missing')
for _, path in ipairs({ '/机密/客户资料', '/私密🌏', '相对/客户资料', './资料', '../客户资料',
  'C:\\机密\\客户资料', '\\\\服务器\\共享\\资料', '相对\\客户资料', '~/机密' }) do
  missing.reset()
  zh.translate({ domain = 'nvim-ui', msgid = 'Cannot read ' .. path })
  local rows = missing.list()
  assert(#rows == 1, 'missing entry was not recorded')
  assert(rows[1].msgid:match('^<redacted sha256:'), 'path not redacted: ' .. path)
  assert(not vim.inspect(rows):find(path, 1, true), 'path leaked into row identity: ' .. path)
end
missing.reset()
zh.translate({ domain = 'nvim-ui', msgid = 'Unknown static label' })
assert(missing.list()[1].msgid == 'Unknown static label', 'safe static label was unnecessarily redacted')
print('PATH_PRIVACY_SPEC=PASS unicode posix windows unc relative static_label')
