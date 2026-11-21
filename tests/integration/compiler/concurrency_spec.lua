local compiler = require('nvim-zh.compiler')
local packs = require('nvim-zh.packs')
local lists = require('nvim-zh.list_display')
local root = vim.env.NVIM_ZH_TMP
local a, b = root .. '/a', root .. '/b'
for _, dir in ipairs({ a, b }) do
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/clang'
  vim.fn.writefile({ '#!/bin/sh', 'echo "clang: error: fixture $(pwd)"', 'exit 3' }, path)
  assert(vim.fn.setfperm(path, 'rwx------') == 1)
end
local original_system = vim.system
local requests = {}
vim.system = function(args, _, cb)
  local path = args[1] == 'sha256sum' and args[3] or args[1]
  local callbacks = requests[path] or {}
  requests[path] = callbacks
  callbacks[args[1] == 'sha256sum' and 'hash' or 'version'] = cb
end
local function finish(dir, version)
  local callbacks = assert(requests[dir .. '/clang'], 'probe used the wrong project path')
  callbacks.hash({ code = 0, stdout = string.rep('a', 64) .. '  fixture' })
  callbacks.version({ code = 0, stdout = 'clang version ' .. version })
end
local original_has, original_reason = packs.has_tool, packs.tool_reason
packs.has_tool = function() return true end
packs.tool_reason = function(id, identity)
  assert(id == 'clang')
  return identity and identity.version == '23.1.5' and 'verified' or 'unsupported_version'
end
compiler.setup({ enabled = true, loclist = true, quickfix = true })
vim.o.shellpipe = '>'
vim.o.makeprg = './clang -fsyntax-only'
vim.o.errorformat = '%m'
vim.cmd.tcd(a)
local win_a = vim.api.nvim_get_current_win()
vim.cmd('silent lmake!')
assert(vim.v.shell_error == 3)
local list_a = vim.fn.getloclist(win_a)[1]
assert(list_a.text:find(a, 1, true))
vim.cmd('tabnew')
vim.cmd.lcd(b)
local win_b = vim.api.nvim_get_current_win()
vim.cmd('silent make!')
assert(vim.v.shell_error == 3)
assert(vim.fn.getqflist()[1].text:find(b, 1, true))
finish(b, '22.1.5')
finish(a, '23.1.5')
assert(vim.wait(1000, function() return compiler.info(win_a).last.results ~= nil end))
assert(compiler.info(win_b).last.reason == 'unsupported_version')
assert(compiler.info(win_a).last.version == '23.1.5')
assert(vim.fn.getqflist({ quickfixtextfunc = 1 }).quickfixtextfunc == '')
assert(type(vim.fn.getloclist(win_a, { quickfixtextfunc = 1 }).quickfixtextfunc) == 'function')
vim.api.nvim_set_current_win(win_a)
vim.cmd.lopen()
assert(lists.raw().raw_text == list_a.text and lists.raw().tool == 'clang')
vim.cmd.lclose()
vim.cmd.lcd(b)
assert(compiler.info(win_a).last == nil)
vim.system, packs.has_tool, packs.tool_reason = original_system, original_has, original_reason
compiler.teardown()
print('COMPILER_CONCURRENCY=PASS relative_executable cross_tab lmake make exit raw asynchronous')
