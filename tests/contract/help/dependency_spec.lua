local help = require('nvim-zh.help')
local function status()
  for _, row in ipairs(help.check({ enabled = true, vimcdoc = true })) do
    if row.name == 'help.vimcdoc' then return row.status end
  end
  error('missing vimcdoc check')
end
local old_rtp = vim.o.runtimepath
local tmp = vim.fn.tempname()
local root = vim.env.NVIM_ZH_ROOT
vim.fn.mkdir(tmp .. '/doc', 'p')
local ok, err = pcall(function()
  vim.o.runtimepath = root .. ',' .. vim.env.VIMRUNTIME
  assert(status() == 'warn', 'bundled help was mistaken for external Vimcdoc')
  vim.fn.writefile({ '*usr_01.txt*  external Chinese help' }, tmp .. '/doc/usr_01.cnx')
  vim.opt.runtimepath:append(tmp)
  assert(status() == 'warn', 'unindexed external document was accepted')
  vim.cmd('helptags ' .. vim.fn.fnameescape(tmp .. '/doc'))
  assert(status() == 'ok', 'indexed independent help hidden behind bundled match was missed')
  vim.fn.delete(tmp .. '/doc', 'rf')
  assert(vim.uv.fs_symlink(root .. '/doc', tmp .. '/doc'), 'could not create help alias fixture')
  assert(status() == 'warn', 'symlink to bundled help was mistaken for independent install')
end)
vim.o.runtimepath = old_rtp
vim.fn.delete(tmp, 'rf')
if not ok then error(err, 0) end
print('HELP_DEPENDENCY_SPEC=PASS self_exclusion indexed_external symlink_alias')
