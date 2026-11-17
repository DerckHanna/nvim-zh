local function check(value, message)
  if not value then error(message, 2) end
end
local root = vim.env.NVIM_ZH_ROOT
local function read(path)
  local file = assert(io.open(path, 'rb'))
  local data = file:read('*a')
  file:close()
  return data
end
local manifest = vim.json.decode(read(root .. '/manifests/upstreams.json'))
local neovim = manifest.upstreams.neovim
-- Version and commit come from the manifest; this spec only checks their shape.
check(type(neovim.version) == 'string' and neovim.version:match('^%d+%.%d+%.%d+$') ~= nil,
  'manifest version must be an x.y.z string')
check(type(neovim.commit) == 'string' and #neovim.commit == 40
  and neovim.commit:match('^[0-9a-f]+$') ~= nil,
  'manifest commit must be a 40-character lowercase hex digest')
local entry = neovim.documents['nvim.txt']
check(entry and entry.translation == 'doc/nvim.cnx' and entry.status == 'complete', 'nvim.txt manifest entry missing')
local upstream_path = vim.env.VIMRUNTIME .. '/doc/nvim.txt'
local version = vim.version()
local running_version = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
-- Same rule as tests/phase8/01_help_catalog_spec.lua: a prerelease build that
-- self-reports the pinned version must not be silently downgraded to unpinned,
-- because that would skip the pinned hash/tag comparisons below.
check(not (running_version == neovim.version and version.prerelease),
  ('runtime %s reports the pinned version %s as a prerelease build; '
    .. 'pinned/unpinned cannot be decided'):format(running_version, neovim.version))
local pinned_runtime = running_version == neovim.version
-- The translated document is pinned to the manifest baseline. Keep its exact
-- source hash and bidirectional tag assertions on that baseline; other versions
-- verify only native help selection/fallback, not false parity with a different
-- runtime. A runtime that does not ship nvim.txt at all is reported rather than
-- aborting on an io.assert from read().
local upstream_present = vim.fn.filereadable(upstream_path) == 1
if pinned_runtime then
  check(upstream_present, 'pinned runtime does not ship ' .. upstream_path)
end
local upstream = upstream_present and read(upstream_path) or nil
if pinned_runtime then
  check(vim.fn.sha256(upstream) == entry.sha256, 'installed upstream nvim.txt differs from manifest')
end
local translated = read(root .. '/doc/nvim.cnx')
local function tags(text)
  local result = {}
  for tag in text:gmatch('%*([^%s%*]+)%*') do result[tag] = true end
  return result
end
local upstream_tags = upstream_present and tags(upstream) or {}
local translated_tags = tags(translated)
if pinned_runtime then
  for tag in pairs(upstream_tags) do check(translated_tags[tag], 'translation missing help tag: ' .. tag) end
  for tag in pairs(translated_tags) do check(upstream_tags[tag], 'translation adds unverified help tag: ' .. tag) end
end
local tags_cn = read(root .. '/doc/tags-cn')
local function contains_tag(index, tag)
  return index:find('\n' .. tag .. '\t', 1, true) ~= nil
    or index:find(tag .. '\t', 1, true) == 1
end
check(contains_tag('literal%tag\tfirst.cnx\t/*literal%tag*', 'literal%tag'),
  'plain first-line tag lookup must not interpret Lua pattern characters')
for tag in pairs(translated_tags) do
  check(contains_tag(tags_cn, tag), 'tags-cn missing ' .. tag)
end
require('nvim-zh').setup()
vim.cmd('help nvim-intro')
check(vim.api.nvim_buf_get_name(0) == root .. '/doc/nvim.cnx', ':help did not select translated nvim.cnx')
-- Fallback must be probed on a document that is permanently excluded from
-- translation. api.txt shipped a doc/api.cnx, so :help api now (correctly)
-- opens the translation; credits.txt is listed in help_exemptions.json and
-- therefore always resolves to the English runtime copy.
vim.cmd('help credits.txt')
check(vim.api.nvim_buf_get_name(0) == vim.env.VIMRUNTIME .. '/doc/credits.txt', ':help did not fall back to English credits.txt')
vim.cmd('help nvim-zh')
check(vim.api.nvim_buf_get_name(0) == root .. '/doc/nvim-zh.cnx', 'plugin Chinese help not found')
print('DOCS_SPEC=PASS upstream_hash=' .. (pinned_runtime and 'match' or ('pinned_' .. neovim.version)) .. ' tags=' .. (pinned_runtime and 'complete' or 'resource_internal') .. ' chinese_help=selected english_fallback=ok')
