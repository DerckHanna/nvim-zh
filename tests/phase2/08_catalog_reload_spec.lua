local zh = require('nvim-zh')
local function equal(actual, expected, message)
  assert(actual == expected, message .. ': ' .. vim.inspect(actual))
end
local root = vim.fn.tempname()
local path = root .. '/lua/nvim-zh/catalogs/generated/nvim-ui.lua'
vim.fn.mkdir(vim.fs.dirname(path), 'p')
local function write(text)
  vim.fn.writefile({ "return { schema=1, domain='nvim-ui', locale='zh_CN', entries={ { msgid='Ready', msgstr='" .. text .. "' } } }" }, path)
end
local old_rtp = vim.o.runtimepath
local ok, err = pcall(function()
  vim.opt.runtimepath:prepend(root)
  write('old text')
  zh.setup({ modules = { core = { enabled = false }, help = { enabled = false }, ui = { notify = false, prompts = false },
    plugins = { auto = false }, diagnostics = { enabled = false }, lsp = { messages = false, progress = false } } })
  equal(zh.translate({ domain = 'nvim-ui', msgid = 'Ready' }), 'old text', 'initial directory')
  local unrelated = {}
  package.loaded['nvim-zh-user-cache-fixture'] = unrelated
  write('new text')
  zh.reload()
  equal(zh.translate({ domain = 'nvim-ui', msgid = 'Ready' }), 'new text', 'reload retained require cache')
  equal(package.loaded['nvim-zh-user-cache-fixture'], unrelated, 'reload evicted an unrelated module')
  vim.fn.writefile({ 'error("invalid rebuilt catalog")' }, path)
  zh.reload()
  equal(zh.translate({ domain = 'nvim-ui', msgid = 'Ready' }), 'Ready', 'broken rebuild did not fall back')
  write('recovered')
  zh.reload()
  equal(zh.translate({ domain = 'nvim-ui', msgid = 'Ready' }), 'recovered', 'reload did not recover')
end)
vim.o.runtimepath = old_rtp
vim.fn.delete(root, 'rf')
package.loaded['nvim-zh-user-cache-fixture'] = nil
if not ok then error(err, 0) end
print('CATALOG_RELOAD_SPEC=PASS disk_changes unrelated_cache error_fallback recovery')
