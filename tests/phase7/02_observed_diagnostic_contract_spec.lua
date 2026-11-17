local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase7/helpers.lua')
local check, equal = h.check, h.equal
local path = vim.env.NVIM_ZH_TEST_CLANGD_OBSERVATION or (vim.env.NVIM_ZH_ROOT .. '/tests/phase7/fixtures/clangd-real-observed.json')
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
local corpus_dir = vim.env.NVIM_ZH_ROOT .. '/tests/phase7/corpus'
local corpus_hashes = observation.corpus_sha256
check(type(corpus_hashes) == 'table', 'observation lacks corpus_sha256')
local corpus_files = vim.fn.globpath(corpus_dir, '*.cpp', false, true)
table.sort(corpus_files)
equal(#corpus_files, 4, 'real corpus file count')
local seen_corpus = {}
for _, corpus_path in ipairs(corpus_files) do
  local name = vim.fs.basename(corpus_path)
  check(type(corpus_hashes[name]) == 'string', 'observation lacks corpus hash: ' .. name)
  equal(vim.fn.sha256(read_bytes(corpus_path)), corpus_hashes[name], 'corpus hash mismatch: ' .. name)
  seen_corpus[name] = true
end
for name in pairs(corpus_hashes) do
  check(seen_corpus[name], 'observation has unknown corpus hash: ' .. name)
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.diagnostic.config({ virtual_text = true, virtual_lines = true, float = true })
h.setup()
local formatter = vim.diagnostic.config().virtual_text.format
local ns = vim.api.nvim_create_namespace('nvim-zh-phase7-real')
local converted, expected = {}, {}
local function convert(raw)
  return {
    lnum = raw.range.start.line, col = raw.range.start.character,
    end_lnum = raw.range['end'].line, end_col = raw.range['end'].character,
    severity = raw.severity, message = raw.message, source = raw.source, code = raw.code,
    user_data = { lsp = vim.deepcopy(raw) },
  }
end
for _, notification in ipairs(observation.push) do
  for _, raw in ipairs(notification.params.diagnostics) do
    table.insert(converted, convert(raw))
    if raw.message == "Redefinition of 'repeated'" then
      expected[raw.message] = "'repeated' 重复定义"
      check(raw.relatedInformation and raw.relatedInformation[1].message == 'Previous definition is here', 'relatedInformation missing')
    elseif raw.message:match("^Use of undeclared identifier '") then
      local name = raw.message:match("^Use of undeclared identifier '(.*)'$")
      expected[raw.message] = "使用了未声明的标识符 '" .. name .. "'"
    elseif raw.message == "Unknown type name 'MissingType'" then
      expected[raw.message] = "未知类型名 'MissingType'"
    else
      expected[raw.message] = raw.message
    end
  end
end
equal(#converted, 6, 'real corpus diagnostic count')
for index, item in ipairs(converted) do
  equal(formatter(item), expected[item.message], 'real diagnostic display mismatch')
  item.bufnr = buf
end
vim.diagnostic.set(ns, buf, converted)
local stored = vim.diagnostic.get(buf, { namespace = ns })
equal(#stored, 6, 'stored diagnostic count changed')
for index, item in ipairs(stored) do
  check(item.message:find('使用了', 1, true) == nil and item.message:find('重复定义', 1, true) == nil and item.message:find('未知类型名', 1, true) == nil, 'stored diagnostic was translated')
  check(item.user_data.lsp.message == item.message, 'user_data.lsp message changed')
  check(vim.deep_equal(item.user_data.lsp, converted[index].user_data.lsp), 'user_data.lsp raw diagnostic changed')
end
check(vim.deep_equal(observation, snapshot), 'raw observation mutated')
vim.diagnostic.setqflist({ namespace = ns })
local qf = vim.fn.getqflist()
local qf_seen = {}
for _, item in ipairs(qf) do qf_seen[item.text] = true end
for _, raw in ipairs(converted) do check(qf_seen[raw.message], 'quickfix source message changed: ' .. raw.message) end
local coverage = require('nvim-zh.diagnostics').info()
equal(coverage.runtime_observed, 18, 'real runtime observed count')
equal(coverage.runtime_translated, 12, 'real runtime translated count')
local note = { message = 'Previous definition is here', source = 'clang' }
equal(formatter(note), '此前的定义在这里', 'real relatedInformation template missing')
for _, response in ipairs(observation.pull) do
  if response.error then
    equal(response.error.code, -32601, 'unexpected pull error')
  else
    for _, raw in ipairs(response.result.items or {}) do
      check(type(raw.message) == 'string' and raw.message == expected[raw.message] or expected[raw.message] ~= nil, 'pull source data missing')
    end
  end
end
require('nvim-zh.diagnostics').teardown()
print(('PHASE7_OBSERVED_DIAGNOSTIC_CONTRACT=PASS push_raw=unchanged pull=%s quickfix=source user_data_lsp=source runtime=12/18'):format(observation.pull_status))
