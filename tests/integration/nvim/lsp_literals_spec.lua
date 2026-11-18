-- Contract for the fixed-upstream LSP/UI display strings that nvim-zh ships.
--
-- Every entry asserted here must be traceable to a literal in the pinned
-- Neovim source and must reach the user through a public seam that nvim-zh
-- already owns (vim.notify, vim.ui.input/select opts). Nothing here may
-- change protocol objects, actions, diagnostics or plugin-private UI.
local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack

local root = vim.env.NVIM_ZH_ROOT
local function read(path)
  local file = assert(io.open(path, 'rb'), 'cannot read ' .. path)
  local data = file:read('*a')
  file:close()
  return data
end

-- Source-of-truth check: the English msgid must still exist verbatim in the
-- pinned Neovim Lua sources. If upstream rewrites or removes a string, this
-- fails loudly instead of shipping a translation nobody can trigger. Only the
-- pinned baseline can answer that: 0.11.5 lacks several of these literals and
-- files (document_color.lua does not exist there) and nightly rewrote others,
-- so the upstream lookup is pinned-only while the translation behaviour
-- asserted below keeps running on every version.
local manifest = vim.json.decode(read(root .. '/manifests/upstreams.json'))
local pinned_version = assert(manifest.upstreams.neovim.version,
  'manifest lacks the pinned neovim version')
local version = vim.version()
local running_version = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
-- Same rule as 01_help_catalog_spec.lua: the manifest is the single source of
-- truth for the pin (this file used to hardcode 0.12.6 a second time), and a
-- prerelease build reporting the pinned version must not be silently
-- classified as unpinned.
check(not (running_version == pinned_version and version.prerelease),
  ('runtime %s reports the pinned version %s as a prerelease build; '
    .. 'pinned/unpinned cannot be decided'):format(running_version, pinned_version))
local pinned = running_version == pinned_version
local runtime_lua = vim.env.VIMRUNTIME .. '/lua/'
local function runtime_sources()
  local files = vim.fn.globpath(runtime_lua, '**/*.lua', false, true)
  table.sort(files)
  local contents = {}
  for _, path in ipairs(files) do
    contents[path] = read(path)
  end
  return contents
end
local sources = pinned and runtime_sources() or {}
local function assert_present(msgid, expected_file)
  if not pinned then return end
  local found = false
  for path, text in pairs(sources) do
    if not vim.endswith(path, expected_file) then goto continue end
    if text:find(msgid, 1, true) then found = true end
    ::continue::
  end
  check(found, ('msgid %q is no longer present in pinned %s'):format(msgid, expected_file))
end

local notify_calls = {}
vim.notify = function(msg, level, opts)
  table.insert(notify_calls, { msg = msg, level = level, opts = opts })
  return 'notify-return'
end
local input_opts, select_opts
vim.ui.input = function(opts, callback) input_opts = opts end
vim.ui.select = function(items, opts, callback) select_opts = opts end

h.setup({ notify = true, prompts = true, select_items = false, echo = false })

-- (msgid, upstream file, expected translation)
local messages = {
  { 'No information available', 'vim/lsp/buf.lua', '没有可用的信息' },
  { 'Empty hover response', 'vim/lsp/buf.lua', '悬停响应为空' },
  { 'No locations found', 'vim/lsp/buf.lua', '未找到位置' },
  { 'No references found', 'vim/lsp/buf.lua', '未找到引用' },
  { 'No code actions available', 'vim/lsp/buf.lua', '没有可用的代码操作' },
  { 'No signature help available', 'vim/lsp/buf.lua', '没有可用的签名帮助' },
  { 'No codelens at current line', 'vim/lsp/codelens.lua', '当前行没有代码透镜' },
  -- Strings a user hits while formatting, renaming, or walking hierarchy and
  -- document-color features. Same public seam (vim.notify), same pin.
  {
    '[LSP] Format request failed, no matching language servers.',
    'vim/lsp/buf.lua',
    '[LSP] 格式化请求失败，没有匹配的语言服务器。',
  },
  {
    '[LSP] Rename, no matching language servers with rename capability.',
    'vim/lsp/buf.lua',
    '[LSP] 重命名：没有支持重命名能力的语言服务器。',
  },
  { 'No item resolved', 'vim/lsp/buf.lua', '未解析出条目' },
  {
    "Language server couldn't provide rename result",
    'vim/lsp/handlers.lua',
    '语言服务器无法提供重命名结果',
  },
  {
    'documentColor is not enabled for this buffer.',
    'vim/lsp/document_color.lua',
    '该 buffer 未启用 documentColor。',
  },
  { 'No color information under cursor.', 'vim/lsp/document_color.lua', '光标下没有颜色信息。' },
  {
    '[LSP] Server does not support linked editing ranges',
    'vim/lsp/linked_editing_range.lua',
    '[LSP] 服务器不支持关联编辑范围',
  },
  {
    'Invalid server TextDocumentSyncKind for textDocumentSync',
    'vim/lsp/protocol.lua',
    'textDocumentSync 的 TextDocumentSyncKind 无效',
  },
}
for _, row in ipairs(messages) do
  local msgid, file, expected = row[1], row[2], row[3]
  assert_present(msgid, file)
  local before = #notify_calls
  vim.notify(msgid)
  equal(#notify_calls, before + 1, 'notify was not forwarded for ' .. msgid)
  equal(notify_calls[#notify_calls].msg, expected, 'notify translation: ' .. msgid)
end

-- Level and opts must still reach the original implementation untouched.
local opts = { title = 'unchanged', data = { value = 1 } }
vim.notify('No locations found', vim.log.levels.WARN, opts)
local last = notify_calls[#notify_calls]
check(last.level == vim.log.levels.WARN, 'notify level changed')
check(last.opts == opts, 'notify opts identity changed')

-- Prompts reach the user through vim.ui.input/select opts.prompt.
assert_present('New Name: ', 'vim/lsp/buf.lua')
vim.ui.input({ prompt = 'New Name: ', scope = 'cursor' }, function() end)
equal(input_opts.prompt, '新名称：', 'rename prompt translation')
equal(input_opts.scope, 'cursor', 'rename prompt changed unrelated opts')

assert_present('Code actions:', 'vim/lsp/buf.lua')
vim.ui.select({ 'a' }, { prompt = 'Code actions:', kind = 'code_action' }, function() end)
equal(select_opts.prompt, '代码操作：', 'code action prompt translation')
equal(select_opts.kind, 'code_action', 'code action prompt changed unrelated opts')

assert_present('Code lenses: ', 'vim/lsp/codelens.lua')
vim.ui.select({ 'a' }, { prompt = 'Code lenses: ', kind = 'codelens' }, function() end)
equal(select_opts.prompt, '代码透镜：', 'codelens prompt translation')

-- Unknown text and dynamic LSP payloads must fall back unchanged.
local before = #notify_calls
vim.notify('Some unknown server message about %s formats')
equal(notify_calls[#notify_calls].msg, 'Some unknown server message about %s formats', 'unknown notify text changed')
local dynamic = 'No locations found in ' .. 'project/src'
vim.notify(dynamic)
equal(notify_calls[#notify_calls].msg, dynamic, 'dynamic payload must not be pattern-matched')
equal(#notify_calls, before + 2, 'fallback forwarding count')

-- Nothing was added for LSP protocol/log-only text.
local zh = require('nvim-zh')
for _, msgid in ipairs({ 'window/logMessage', 'Invalid path: ' }) do
  equal(zh.translate({ domain = 'nvim-ui', msgid = msgid }), msgid, 'unexpected translation: ' .. msgid)
end

print(('LSP_UI_TEXT_SPEC=PASS notify=%d prompts=3 pinned=%s'):format(#messages, tostring(pinned)))
