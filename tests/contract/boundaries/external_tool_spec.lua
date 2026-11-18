local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua')
local original_system, original_shell, original_systemlist = vim.system, vim.fn.system, vim.fn.systemlist
h.setup()
h.equal(vim.system, original_system, 'adapter touched vim.system')
h.equal(vim.fn.system, original_shell, 'adapter touched shell output')
h.equal(vim.fn.systemlist, original_systemlist, 'adapter touched shell lines')
-- Compare bytes from actual child output, including non-UTF-8 and NUL.
local bytes = 'raw\000\255\nRedefinition of x\n'
local result = vim.system({ 'cat' }, { stdin = bytes }):wait()
h.equal(result.code, 0, 'child failed')
h.equal(result.stdout, bytes, 'external tool stdout bytes changed')
h.equal(result.stderr, '', 'external tool stderr changed')
local shell = vim.fn.system({ 'printf', '%s', "Use of undeclared identifier 'x'" })
h.equal(shell, "Use of undeclared identifier 'x'", 'shell bytes translated')
print('EXTERNAL_TOOL_SPEC=PASS process_bytes shell_bytes system_functions=unchanged')
