local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/clangd_helpers.lua')
local check, equal = h.check, h.equal
h.setup()
local formatter = vim.diagnostic.config().virtual_text.format
check(type(formatter) == 'function', 'diagnostic formatter not installed')
local buf = vim.api.nvim_get_current_buf()
local ns = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/diagnostic_helpers.lua').client(buf)
local function diagnostic(message, source, code)
  return { bufnr = buf, namespace = ns, message = message, source = source or 'clang', code = code or 'fixture', lnum = 0, col = 0 }
end
local cases = {
  { "Redefinition of '重复'", "'重复' 重复定义" },
  { "Use of undeclared identifier 'missing_name'", "使用了未声明的标识符 'missing_name'" },
  { "Use of undeclared identifier '路径变量'", "使用了未声明的标识符 '路径变量'" },
  { "Use of undeclared identifier 'foo\nbar'", "使用了未声明的标识符 'foo\nbar'" },
  { "Use of undeclared identifier '{name}'", "使用了未声明的标识符 '{name}'" },
  { "Unknown type name 'MissingType'", "未知类型名 'MissingType'" },
  { "Expected ';' at end of declaration (fix available)", "声明末尾缺少 ';'（有可用修复）" },
  { "No matching function for call to 'sum'\n\nmain.cpp:3:5: note: candidate function not viable: requires 2 arguments, but 1 was provided",
    "找不到与调用匹配的函数 'sum'\n\nmain.cpp:3:5: 注释: 候选函数不可用：需要 2 个实参，但提供了 1 个" },
  { "In included file: unknown type name 'Widget'", "在包含的文件中：未知类型名 'Widget'" },
  { "Use of undeclared identifier 'countt'; did you mean 'count'?", "使用了未声明的标识符 'countt'，是否想使用 'count'？" },
  { 'Candidate function not viable: requires 2 arguments, but no arguments were provided',
    '候选函数不可用：需要 2 个实参，但未提供实参' },
  { "Candidate function not viable: requires single argument 'value', but no arguments were provided",
    "候选函数不可用：需要一个实参 'value'，但未提供实参" },
  { 'Too few arguments to function call, expected at least 2, have 1',
    '函数调用的实参太少，至少需要 2 个，提供了 1 个' },
  { 'an unknown diagnostic', 'an unknown diagnostic' },
}
for _, case in ipairs(cases) do
  equal(formatter(diagnostic(case[1])), case[2], 'clangd template/fallback mismatch')
end
equal(formatter(diagnostic('Use nullptr', 'clang-tidy')), '请使用 nullptr', 'clang-tidy diagnostic not translated')
equal(formatter(diagnostic("Use of undeclared identifier 'other'", 'other-server')), "Use of undeclared identifier 'other'", 'unknown server was translated')
local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('clangd-injected-translation-error') end
equal(formatter(diagnostic("Redefinition of 'x'")), "Redefinition of 'x'", 'translator exception did not fall back')
engine.translate = original_translate
local long_name = string.rep('x', 9000)
equal(formatter(diagnostic("Use of undeclared identifier '" .. long_name .. "'")), "Use of undeclared identifier '" .. long_name .. "'", 'over-limit diagnostic did not fall back')
local sentinel = {}
local diagnostics = require('nvim-zh.diagnostics')
diagnostics.teardown()
vim.diagnostic.config({ virtual_text = { format = function() return sentinel end }, virtual_lines = false, float = false })
h.setup(true)
equal(vim.diagnostic.config().virtual_text.format(diagnostic('anything')), sentinel, 'non-string user formatter return identity changed')
local info = diagnostics.info()
check(info.static_entries == nil and info.corpus_entries == nil and info.corpus_translated == nil,
  'diagnostics publishes fixture counts as product coverage')
equal(require('nvim-zh').translate({ domain = 'clangd', context = 'redefinition', msgid = "Redefinition of 'x'", formatted = true }),
  "'x' 重复定义", 'production template unavailable after refresh')
local inventory = require('nvim-zh').stats().static.domains
local count
for _, row in ipairs(inventory) do if row.domain == 'clangd' then count = row.entries end end
check(type(count) == 'number' and count >= 4, 'loaded clangd inventory missing')

-- Include Cleaner, .clangd config, Serialization & Frontend in clangd
equal(formatter(diagnostic('Included header <stdio.h> is not used directly (fix available)', 'clangd', 'unused-includes')),
  '头文件 <stdio.h> 未被直接使用（有可用修复）', 'clangd unused-includes not translated')
equal(formatter(diagnostic('No header providing "std::vector" is directly included', 'clangd', 'missing-includes')),
  '没有直接包含提供 "std::vector" 的头文件', 'clangd missing-includes not translated')
local config_cases = {
  { "Invalid UnusedIncludes value 'Bad'. Valid values are Strict, None.",
    "无效的 UnusedIncludes 值 'Bad'。有效值为 Strict, None。" },
  { "Unknown CompileFlags key 'Ad'; did you mean 'Add'?",
    "未知的 CompileFlags 键 'Ad'，是否想使用 'Add'？" },
  { "Unknown CompileFlags key 'Bogus'",
    "未知的 CompileFlags 键 'Bogus'" },
  { 'CompilationDatabase invalid number',
    'CompilationDatabase 包含无效数字' },
  { 'Index should be a dictionary',
    'Index 应为字典' },
  { 'Expected scalar or list of scalars',
    '需要标量值或标量列表' },
  { 'External must be either a scalar or a mapping.',
    'External 必须是标量或映射。' },
  { "Only scalar value supported for External is 'None'",
    "External 支持的唯一标量值是 'None'" },
}
for _, case in ipairs(config_cases) do
  equal(formatter(diagnostic(case[1], 'clangd-config')), case[2], 'clangd-config translation mismatch')
end
equal(formatter(diagnostic("PCH file 'a.pch' not found", 'clang')),
  "未找到PCH 文件 'a.pch'", 'clangd Serialization diagnostic not translated')
equal(formatter(diagnostic("Virtual filesystem overlay file '/tmp/missing.yaml' not found", 'clang')),
  "未找到虚拟文件系统叠加文件 '/tmp/missing.yaml'", 'clangd Frontend VFS diagnostic not translated')
equal(formatter(diagnostic("Module map file 'module.modulemap' not found", 'clang')),
  "找不到模块映射文件 'module.modulemap'", 'clangd Frontend module map diagnostic not translated')

-- clang-tidy forwarding, analyzer path notes, driver fallback, errorformat & clangd UI keys
for _, pack in ipairs({ 'clang', 'clang-tidy' }) do
  local seeded = vim.system({
    vim.env.PYTHON or 'python3',
    vim.env.NVIM_ZH_ROOT .. '/tests/support/pack_fixture.py',
    vim.env.NVIM_ZH_ROOT,
    vim.env.XDG_DATA_HOME,
    pack,
  }):wait()
  equal(seeded.code, 0, 'failed to seed fixture pack: ' .. pack)
end
local refreshed
require('nvim-zh').refresh(function(res) refreshed = res end)
check(vim.wait(3000, function() return refreshed ~= nil end) and refreshed.ok, 'refresh failed after seeding packs')
local diags_mod = require('nvim-zh.diagnostics')
equal(diags_mod.match_forwarded('Taking true branch', 'clang-analyzer-core.DivideZero', true),
  '进入条件为真的分支', 'forwarded analyzer branch note not translated')
equal(diags_mod.match_forwarded("Assuming 'x' is equal to 0", 'clang-analyzer-core.DivideZero', true),
  "假定 'x' 等于 0", 'forwarded analyzer condition note not translated')
equal(diags_mod.match_forwarded('Division by zero', 'clang-analyzer-core.DivideZero', true),
  '除以零', 'forwarded analyzer trailing note not translated')
equal(diags_mod.match_forwarded('Opened file is never closed; potential resource leak', 'clang-analyzer-alpha.unix.SimpleStream', false),
  '已打开的文件从未关闭；可能存在资源泄漏', 'forwarded alpha analyzer diagnostic not translated')
local tm = require('nvim-zh.tool_message')
local drv_msg, drv_status = tm.match_message('clang', "virtual filesystem overlay file '/tmp/missing.yaml' not found", nil, 'error', 'driver')
equal(drv_status, 'translated', 'driver Frontend fallback failed')
equal(drv_msg, "未找到虚拟文件系统叠加文件 '/tmp/missing.yaml'", 'driver Frontend fallback text mismatch')
vim.cmd('compiler nvim-zh-clang')
local qf_parsed = vim.fn.getqflist({ lines = { 'foo.c:12: fatal error: bar', 'foo.c:15: remark: baz' } }).items
equal(qf_parsed[1].valid, 1, 'line-only fatal error not parsed by errorformat')
equal(qf_parsed[1].lnum, 12, 'line-only fatal error lnum wrong')
equal(qf_parsed[2].valid, 1, 'line-only remark not parsed by errorformat')
equal(qf_parsed[2].lnum, 15, 'line-only remark lnum wrong')

local zh = require('nvim-zh')
local ui_cases = {
  { 'code_action', 'Add using-declaration for std::vector and remove qualifier', '为 std::vector 添加 using 声明并移除限定符' },
  { 'code_action', 'Declare implicit copy members', '声明隐式 copy 成员' },
  { 'code_action', 'Dump Expr AST', '导出 Expr 的 AST' },
  { 'code_action', 'Show Record layout', '显示 Record 布局' },
  { 'code_action', "Expand macro 'MAX'", "展开宏 'MAX'" },
  { 'code_action', 'Swap operands to +', '交换操作数为 +' },
  { 'code_action', 'Include <vector>', '包含 <vector>' },
  { 'code_action', 'Include <vector> for symbol std::vector', '包含 <vector> 以使用符号 std::vector' },
  { 'code_action', "remove ';'", "移除 ';'" },
  { 'code_action', "insert ';'", "插入 ';'" },
  { 'code_action', 'Apply fix: Add return', '应用修复：Add return' },
  { 'hover_kind', 'param', '形参' },
  { 'hover_kind', 'conversion-func', '转换函数' },
  { 'hover_kind', 'template-type-param', '类型模板形参' },
  { 'hover_kind', 'non-type-template-param', '非类型模板形参' },
  { 'hover_kind', 'module', '模块' },
  { 'hover_kind', 'using', 'using 声明' },
  { 'signature_help', 'Signature Help: clangd', '函数签名：clangd' },
}
for _, case in ipairs(ui_cases) do
  equal(zh.translate({ domain = 'clangd', context = case[1], msgid = case[2], formatted = true }),
    case[3], 'clangd UI key mismatch: ' .. case[1] .. ':' .. case[2])
end
print('CLANGD_TEMPLATES_SPEC=PASS templates unicode newline placeholders long unknown formatter')
