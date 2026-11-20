local M = {}
local fs = require('nvim-zh.fs')
local paths = require('nvim-zh.paths')
local catalog = require('nvim-zh.catalog')
local uv = vim.uv
local active, installed, code_root
local initial_ok, running = pcall(fs.json, paths.root .. '/resources/manifest.json', 256 * 1024)
if not initial_ok or type(running) ~= 'table' or type(running.version) ~= 'string'
  or type(running.implementation) ~= 'table' or type(running.implementation.id) ~= 'string'
  or #running.implementation.id ~= 64 or not running.implementation.id:match('^[a-f0-9]+$') then
  running = { version = '开发版（清单不可用）', implementation = {} }
end

local function manifest(root)
  local value = fs.json(root .. '/manifest.json', 256 * 1024)
  assert(value.schema == 1 and value.runtime_api == 1, '资源格式不兼容，请重启或检查发布版本')
  assert(type(value.version) == 'string' and #value.version < 80, '非法版本元数据')
  assert(type(value.bundle) == 'table' and fs.index_id(value.bundle.files) == value.bundle.id, '资源集标识不匹配')
  assert(type(value.implementation) == 'table'
    and fs.index_id(value.implementation.files) == value.implementation.id, '实现标识不匹配')
  return value
end

local function publish(base, id, data, release)
  fs.mkdir(base)
  local destination = base .. '/' .. id
  if uv.fs_stat(destination) then return destination end
  local stage = fs.unique(base .. '/stage')
  fs.mkdir(stage)
  local ok, err = pcall(function()
    for name, bytes in pairs(data) do fs.write(stage .. '/' .. name, bytes) end
    if release then fs.write(stage .. '/manifest.json', vim.json.encode(release)) end
    local renamed, why = uv.fs_rename(stage, destination)
    assert(renamed or uv.fs_stat(destination), why)
  end)
  if uv.fs_stat(stage) then vim.fn.delete(stage, 'rf') end
  if not ok then error(err, 0) end
  return destination
end

function M.freeze()
  if code_root then return end
  local meta = manifest(paths.root .. '/resources')
  assert(meta.implementation.id == running.implementation.id, '初始化期间实现已更新，请重启 Neovim')
  for name in pairs(meta.implementation.files) do
    assert(name == 'VERSION' or name:match('^lua/[%w_./%-]+%.lua$')
      or name:match('^plugin/[%w_./%-]+%.lua$')
      or name:match('^compiler/[%w_./%-]+%.vim$'), '非法实现文件路径')
  end
  local bytes = fs.verify(paths.root, meta.implementation.files)
  local candidate = publish(paths.data() .. '/implementations', meta.implementation.id, bytes)
  fs.verify(candidate, meta.implementation.files)
  -- Freeze future require() calls too; an update must not mix old/new Lua modules.
  local rtp = {}
  for _, path in ipairs(vim.opt.runtimepath:get()) do
    if (uv.fs_realpath(path) or path) ~= paths.root then rtp[#rtp + 1] = path end
  end
  table.insert(rtp, 1, candidate)
  vim.opt.runtimepath = rtp
  code_root = candidate
end

local function prepare(root)
  local meta = manifest(root)
  local data = fs.verify(root, meta.bundle.files)
  local contract_data = assert(data['adapter-contract.json'], '缺少适配器资源契约')
  local contract = vim.json.decode(contract_data)
  assert(contract.id == meta.adapter_contract, '适配器资源契约不匹配')
  if contract.id ~= running.adapter_contract then return nil, 'adapter_restart' end
  local sources = {}
  local required = catalog.builtin_domains()
  for _, domain in ipairs(required) do
    local name = 'catalogs/' .. domain .. '.json'
    assert(data[name], '缺少翻译目录：' .. domain)
    local source = vim.json.decode(data[name])
    assert(source.domain == domain, '目录 domain 不匹配')
    sources[domain] = source
  end
  require('nvim-zh.catalog').prepare_sources(sources)
  assert(data['help/doc/tags'] and data['help/doc/tags-cn'] and data['help/doc/nvim-zh.cnx'], '缺少 Help 索引或文档')
  for _, line in ipairs(vim.split(data['help/doc/tags-cn'], '\n', { trimempty = true })) do
    if line:sub(1, 1) ~= '!' then
      local file = line:match('^[^\t]+\t([^\t]+)\t')
      assert(file and file:match('^[%w_.%-]+%.cnx$') and data['help/doc/' .. file], 'Help 索引引用缺失文档')
    end
  end
  local mo = assert(data['native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'], '缺少核心 MO')
  assert(#mo >= 28 and (mo:sub(1, 4) == '\222\018\004\149' or mo:sub(1, 4) == '\149\004\018\222'), '无效 MO 头')
  local summary = vim.json.decode((assert(data['summary.json'], '缺少资源摘要')))
  assert(summary.schema == 1 and type(summary.domains) == 'table' and type(summary.native) == 'table'
    and type(summary.native.probe) == 'table' and type(summary.native.probe.msgid) == 'string'
    and type(summary.native.probe.msgstr) == 'string', '资源摘要格式错误')
  assert(type(summary.baseline) == 'string' and type(summary.help) == 'table'
    and type(summary.help.complete) == 'number' and type(summary.help.excluded) == 'number'
    and type(summary.native.supplement) == 'number', '资源统计格式错误')
  require('nvim-zh.mo').validate(mo, summary.native.probe)
  for _, domain in ipairs(required) do
    assert(summary.domains[domain] == #sources[domain].entries, '目录数量与清单不匹配')
  end
  local destination = publish(paths.data() .. '/resources', meta.bundle.id, data, meta)
  fs.verify(destination, meta.bundle.files)
  return { manifest = meta, root = destination, sources = sources, summary = summary }
end

function M.prepare()
  local ok_meta, meta = pcall(manifest, paths.root .. '/resources')
  installed = ok_meta and meta or nil
  if not ok_meta then error(meta, 0) end
  return prepare(paths.root .. '/resources')
end

function M.recover()
  local ok, result = pcall(function()
    local state = fs.json(paths.data() .. '/state.json', 256 * 1024)
    assert(type(state.active) == 'string' and state.active:match('^[a-f0-9]+$') and #state.active == 64)
    return prepare(paths.data() .. '/resources/' .. state.active)
  end)
  return ok and result or nil
end

function M.commit(candidate)
  local previous = active
  fs.write(paths.data() .. '/state.json', vim.json.encode({ schema = 1,
    active = candidate.manifest.bundle.id, previous = previous and previous.manifest.bundle.id or nil }))
  active = candidate
end

function M.active() return active end
function M.running() return vim.deepcopy(running) end
function M.info()
  return {
    running_version = running.version, running_implementation = running.implementation.id,
    installed_version = installed and installed.version or nil,
    installed_implementation = installed and installed.implementation.id or nil,
    active_bundle = active and active.manifest.bundle.id or nil,
    installed_bundle = installed and installed.bundle.id or nil,
    restart_required = installed ~= nil and installed.implementation.id ~= running.implementation.id,
    summary = active and vim.deepcopy(active.summary) or nil,
  }
end

function M.fingerprint() return fs.fingerprint(paths.root .. '/resources/manifest.json') end
return M
