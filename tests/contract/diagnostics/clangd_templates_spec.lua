local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/clangd_helpers.lua')
local check, equal = h.check, h.equal
h.setup()
local formatter = vim.diagnostic.config().virtual_text.format
check(type(formatter) == 'function', 'diagnostic formatter not installed')
local function diagnostic(message, source)
  return { message = message, source = source or 'clang', code = 'fixture', lnum = 0, col = 0 }
end
local cases = {
  { "Redefinition of '重复'", "'重复' 重复定义" },
  { "Use of undeclared identifier 'missing_name'", "使用了未声明的标识符 'missing_name'" },
  { "Use of undeclared identifier '路径变量'", "使用了未声明的标识符 '路径变量'" },
  { "Use of undeclared identifier 'foo\nbar'", "使用了未声明的标识符 'foo\nbar'" },
  { "Use of undeclared identifier '{name}'", "使用了未声明的标识符 '{name}'" },
  { "Unknown type name 'MissingType'", "未知类型名 'MissingType'" },
  { "Expected ';' at end of declaration (fix available)", "Expected ';' at end of declaration (fix available)" },
  { 'an unknown diagnostic', 'an unknown diagnostic' },
}
for _, case in ipairs(cases) do
  equal(formatter(diagnostic(case[1])), case[2], 'clangd template/fallback mismatch')
end
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
print('CLANGD_TEMPLATES_SPEC=PASS templates unicode newline placeholders long unknown formatter')
