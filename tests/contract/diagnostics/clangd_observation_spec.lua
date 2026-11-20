local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/clangd_helpers.lua')
local check, equal = h.check, h.equal
local path = vim.env.NVIM_ZH_TEST_CLANGD_OBSERVATION or (vim.env.NVIM_ZH_ROOT .. '/tests/fixtures/clangd/observed.json')
local observation = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
local snapshot = vim.deepcopy(observation)

-- Bind every recorded observation to the corpus that produced it. Otherwise a
-- changed .cpp file can silently reuse stale diagnostics while still printing
-- a real-observation PASS.
local function read_bytes(file_path)
  local file = assert(io.open(file_path, 'rb'))
  local data = file:read('*a')
  file:close()
  return data
end
local corpus_dir = vim.env.NVIM_ZH_ROOT .. '/tests/fixtures/clangd/corpus'
local corpus_hashes = observation.corpus_sha256
check(type(corpus_hashes) == 'table', 'observation lacks corpus_sha256')
local corpus_count = 0
-- Check the files recorded by this session, including the original four-file
-- fixture. The live harness records every sample in the expanded corpus.
for name, hash in pairs(corpus_hashes) do
  check(name == vim.fs.basename(name) and name:match('%.cpp$'), 'invalid corpus filename: ' .. name)
  local corpus_path = corpus_dir .. '/' .. name
  check(vim.fn.filereadable(corpus_path) == 1, 'observation has unknown corpus hash: ' .. name)
  equal(vim.fn.sha256(read_bytes(corpus_path)), hash, 'corpus hash mismatch: ' .. name)
  corpus_count = corpus_count + 1
end
check(corpus_count >= 4, 'real corpus file count')

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.diagnostic.config({ virtual_text = true, virtual_lines = true, float = true })
h.setup()
local formatter = vim.diagnostic.config().virtual_text.format
local ns = vim.api.nvim_create_namespace('nvim-zh-clangd-observation')
local converted, expected = {}, {}
local translations = {
  ["Redefinition of 'repeated'"] = "'repeated' 重复定义",
  ["Use of undeclared identifier 'missing_name'"] = "使用了未声明的标识符 'missing_name'",
  ["Use of undeclared identifier '路径变量'"] = "使用了未声明的标识符 '路径变量'",
  ["Unknown type name 'MissingType'"] = "未知类型名 'MissingType'",
  ["Expected '(' for function-style cast or type construction"] = "函数式类型转换或类型构造缺少 '('",
  ["Expected ';' at end of declaration (fix available)"] = "声明末尾缺少 ';'（有可用修复）",
  ["'nonexistent_header_for_nvim_zh.hpp' file not found"] = "找不到文件 'nonexistent_header_for_nvim_zh.hpp'",
  ["No matching function for call to object of type 'Overloads'"] = "找不到可调用 'Overloads' 类型对象的匹配函数",
  ["Expected ')'"] = "此处缺少 ')'",
  ["Expected function body after function declarator"] = "函数声明符后缺少函数体",
  ["No viable conversion from returned value of type 'Holder<int>' to function return type 'int'"] =
    "无法从 returned value of type 'Holder<int>' 转换为 function return type 'int'",
  ["Invalid operands to binary expression ('Holder<int>' and 'Holder<int>')"] =
    "二元表达式的操作数类型无效（'Holder<int>' 和 'Holder<int>'）",
  ["Cannot initialize a variable of type 'const char *' with an rvalue of type 'int'"] =
    "不能用 'int' 类型的右值初始化 'const char *' 类型的变量",
  ["No member named 'absent' in 'Holder'"] = "'Holder' 中没有名为 'absent' 的成员",
  ["No matching constructor for initialization of 'Widget'"] = "找不到可用于初始化 'Widget' 的构造函数",
  ["Type 'double' cannot be narrowed to 'int' in initializer list (fix available)"] =
    "初始化列表中不能将 'double' 类型窄化为 'int'（有可用修复）",
  ["Implicit conversion from 'double' to 'int' changes value from 3.5 to 3"] =
    "从 'double' 到 'int' 的隐式转换将值从 3.5 改为 3",
  ["Read-only variable is not assignable"] = "只读变量不可赋值",
}
local function convert(raw)
  return {
    lnum = raw.range.start.line, col = raw.range.start.character,
    end_lnum = raw.range['end'].line, end_col = raw.range['end'].character,
    severity = raw.severity, message = raw.message, source = raw.source, code = raw.code,
    user_data = { lsp = vim.deepcopy(raw) },
  }
end
for _, notification in ipairs(observation.push) do
  local name = vim.fs.basename(vim.uri_to_fname(notification.params.uri))
  check(corpus_hashes[name], 'observation lacks corpus hash: ' .. name)
  for _, raw in ipairs(notification.params.diagnostics) do
    table.insert(converted, convert(raw))
    expected[raw.message] = translations[raw.message] or raw.message
    if raw.message == "Redefinition of 'repeated'" then
      check(raw.relatedInformation and raw.relatedInformation[1].message == 'Previous definition is here',
        'relatedInformation missing')
    end
  end
end
check(#converted >= 6, 'real corpus diagnostic count')
local translated_count = 0
for _, item in ipairs(converted) do
  local display = formatter(item)
  equal(display, expected[item.message], 'real diagnostic display mismatch')
  if expected[item.message] ~= item.message then translated_count = translated_count + 1 end
  item.bufnr = buf
end
local coverage = require('nvim-zh.diagnostics').info()
equal(coverage.runtime_observed, #converted, 'real runtime observed count')
equal(coverage.runtime_translated, translated_count, 'real runtime translated count')
vim.diagnostic.set(ns, buf, converted)
local stored = vim.diagnostic.get(buf, { namespace = ns })
equal(#stored, #converted, 'stored diagnostic count changed')
for index, item in ipairs(stored) do
  check(item.message:find('使用了', 1, true) == nil and item.message:find('重复定义', 1, true) == nil and item.message:find('未知类型名', 1, true) == nil, 'stored diagnostic was translated')
  check(item.user_data.lsp.message == item.message, 'user_data.lsp message changed')
  check(vim.deep_equal(item.user_data.lsp, converted[index].user_data.lsp), 'user_data.lsp raw diagnostic changed')
end
check(vim.deep_equal(observation, snapshot), 'raw observation mutated')
vim.diagnostic.setqflist({ namespace = ns, open = false })
local qf = vim.fn.getqflist()
local qf_seen = {}
for _, item in ipairs(qf) do qf_seen[item.text] = true end
for _, raw in ipairs(converted) do
  local message = vim.fn.has('nvim-0.12') == 1 and expected[raw.message] or raw.message
  check(qf_seen[message], 'quickfix display mismatch: ' .. message)
end
local note = { message = 'Previous definition is here', source = 'clang' }
equal(formatter(note), '此前的定义在这里', 'real relatedInformation template missing')
for _, response in ipairs(observation.pull) do
  if response.error then
    equal(response.error.code, -32601, 'unexpected pull error')
  else
    for _, raw in ipairs(response.result.items or {}) do
      check(type(raw.message) == 'string' and expected[raw.message] ~= nil, 'pull source data missing')
    end
  end
end
require('nvim-zh.diagnostics').teardown()
print(('CLANGD_OBSERVED_DIAGNOSTIC_CONTRACT=PASS push_raw=unchanged pull=%s user_data_lsp=source runtime=%d/%d')
  :format(observation.pull_status, translated_count, #converted))
