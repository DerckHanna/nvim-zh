local fs = require('nvim-zh.fs')
local store = require('nvim-zh.pack_store')
local packs = require('nvim-zh.packs')
local origin = 'https://raw.githubusercontent.com/DerckHanna/nvim-zh/packs/catalog.json'
local release = 'https://github.com/DerckHanna/nvim-zh/releases/download/'
local known = 'clangd version 23.1.5 linux x86_64-pc-linux-gnu'
local items = {}
for i = 0, 2 do
  local version = '0.1.' .. i
  items[#items + 1] = { id = 'clangd', version = version, executable = 'clangd', locale = 'zh_CN', sdk = 1,
    url = release .. 'packs-clangd-v' .. version .. '/clangd-zh_CN.json', sha256 = string.rep(tostring(i), 64), size = 128,
    tool = i > 0 and { protocol = 'lsp', server = 'clangd',
      versions = { [known] = { 'textDocument/publishDiagnostics' } } } or nil }
end
fs.write(store.root() .. '/catalogs/official.json', vim.json.encode({
  origin = origin, checked_at = os.time(), body = vim.json.encode({ schema = 1, packages = items }),
}))
local system, get_clients = vim.system, vim.lsp.get_clients
vim.system = function(argv, ...) assert(argv[1] ~= 'curl', 'query used the network'); return system(argv, ...) end
local unknown = { id = 12, initialized = true, server_info = { name = 'clangd', version = 'clangd version 23.1.4' } }
local verified = { id = 13, initialized = true, server_info = { name = 'clangd', version = known } }
local current = {}
local all = { unknown, verified }
vim.lsp.get_clients = function(filter) return filter.bufnr and current or all end

local function row()
  return assert(vim.iter(packs.rows()):find(function(item) return item.id == 'clangd' end))
end

current = { unknown }
assert(row().update == nil and #row().options == 3)
assert(row().options[3].compatibility == 'legacy_pack' and not row().options[3].recommended)
current = { verified, unknown }
assert(row().update.version == '0.1.2' and row().update.compatibility == 'verified')
current, all = {}, {}
assert(not row().update and #row().options == 3)
vim.cmd('NvimZhPacks search clangd')
vim.system, vim.lsp.get_clients = system, get_clients
print('PACK_SELECTION_SPEC=PASS local_index explicit_history mixed_clients current_buffer network_free')
