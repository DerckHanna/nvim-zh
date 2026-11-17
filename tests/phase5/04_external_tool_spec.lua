local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase5/helpers.lua')
local equal = h.equal
local path = vim.env.NVIM_ZH_ROOT .. '/tests/phase5/fixtures/external-tool.json'
local before = table.concat(vim.fn.readfile(path, 'b'), '\n')
local snapshot = vim.fn.json_decode(before)
local original_system, original_systemlist = vim.system, vim.fn.system
h.setup()
equal(vim.system, original_system, 'external tool adapter touched vim.system')
equal(vim.fn.system, original_systemlist, 'external tool adapter touched shell output')
local after = table.concat(vim.fn.readfile(path, 'b'), '\n')
equal(after, before, 'external tool raw fixture changed')
equal(snapshot.returncode, 1, 'external tool return code fixture changed')
equal(snapshot.parsed.file, 'main.cpp', 'external tool parsed file changed')
print('EXTERNAL_TOOL_SPEC=PASS raw_bytes=unchanged no_safe_display_seam=inventory_only')
