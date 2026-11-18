local function check(value, message)
  if not value then error(message, 2) end
end
local root = vim.env.NVIM_ZH_TMP .. '/e2'
local doc = root .. '/doc'
vim.fn.mkdir(doc, 'p')
vim.fn.writefile({ '中文探针', '*nvim-zh-probe*', '这是简体中文帮助。' }, doc .. '/probe.cnx')
vim.opt.runtimepath:prepend(root)
vim.o.helplang = 'cn,en'
vim.cmd('helptags ' .. vim.fn.fnameescape(doc))
local tags = table.concat(vim.fn.readfile(doc .. '/tags-cn'), '\n')
check(tags:find('nvim%-zh%-probe') ~= nil, 'tags-cn does not contain probe tag')
vim.cmd('help nvim-zh-probe')
check(vim.api.nvim_buf_get_name(0):sub(-9) == 'probe.cnx', 'translated help was not opened')
check(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == '中文探针', 'translated help content mismatch')
vim.cmd('help credits.txt')
check(vim.api.nvim_buf_get_name(0) == vim.env.VIMRUNTIME .. '/doc/credits.txt', 'English fallback was not opened')
print('E2_HELP_STATUS=PASS translated=.cnx tags=tags-cn fallback=en')
