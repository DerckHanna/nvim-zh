local M = {}
local fs = require('nvim-zh.fs')
local uv = vim.uv
M.limit = 40 * 1024 * 1024
local function root() return require('nvim-zh.paths').data() .. '/packs' end
M.root = root

function M.id(value)
  return type(value) == 'string' and #value <= 80 and value:match('^[a-z0-9][a-z0-9_.%-]*$')
    and not value:find('..', 1, true)
end

function M.digest(value)
  return type(value) == 'string' and #value == 64 and value:match('^[a-f0-9]+$')
end

function M.version(value)
  return type(value) == 'string' and #value <= 40 and value:match('^%d+%.%d+%.%d+$')
end

function M.https(value)
  return type(value) == 'string' and #value <= 2048 and value:match('^https://[%w.%-]+[:/%w_.~?&=+%%#%-]*$')
end

local function record_path(id)
  assert(M.id(id), '无效的汉化包 ID')
  return root() .. '/state/' .. id
end

local function scans(path)
  fs.safe(path)
  local scan, err, code = uv.fs_scandir(path)
  if not scan and code ~= 'ENOENT' then error(err or '无法读取包目录', 0) end
  return function() if scan then return uv.fs_scandir_next(scan) end end
end

function M.record(id)
  local path, latest, file = record_path(id), 0, nil
  for name in scans(path) do
    local sequence = tonumber(name:match('^(%d+)%.json$'))
    if sequence and sequence > latest then latest, file = sequence, name end
  end
  if not file then return { generation = 0 } end
  local value = fs.json(path .. '/' .. file, 64 * 1024)
  assert(value.schema == 1 and value.generation == latest and value.id == id, '包登记已损坏：' .. id)
  for _, key in ipairs({ 'selected', 'previous' }) do
    local item = value[key]
    if item then
      assert(M.version(item.version) and M.digest(item.sha256) and type(item.allow_lua) == 'boolean'
        and type(item.source) == 'string' and (item.source == 'local' or M.https(item.origin)), '无效的包登记')
    end
  end
  return value
end

function M.records()
  local records = {}
  for id, kind in scans(root() .. '/state') do
    if M.id(id) and kind == 'directory' then
      local ok, record = pcall(M.record, id)
      records[id] = ok and record or { error = tostring(record) }
    end
  end
  return records
end

-- Each generation is a compare-and-swap. The hard link publishes a complete
-- record, and an interrupted writer leaves no lock that survives its process.
function M.commit(id, expected, record)
  local folder = record_path(id)
  assert(M.record(id).generation == expected, '包登记已变更，请重试')
  record.schema, record.id, record.generation = 1, id, expected + 1
  local pending = fs.unique(folder .. '/pending')
  fs.write(pending, vim.json.encode(record))
  local ok, err, code = uv.fs_link(pending, folder .. '/' .. record.generation .. '.json')
  uv.fs_unlink(pending)
  assert(ok, code == 'EEXIST' and '包登记已变更，请重试' or err)
end

local function validate_spec(m, files)
  local spec = m.adapter
  if not spec then
    assert(not files['adapter/entry.lua'], '适配入口缺少清单')
    return
  end
  assert(type(spec) == 'table' and spec.domain == m.domain and M.https(spec.repository)
    and type(spec.surfaces) == 'table' and type(spec.targets) == 'table'
    and vim.islist(spec.modules) and vim.islist(spec.lazy_names), '适配清单无效')
  for _, list in ipairs({ spec.modules, spec.lazy_names }) do
    for _, name in ipairs(list) do assert(M.id(name:lower()), '非法模块名称') end
  end
  local paths = {}
  for name, surface in pairs(spec.surfaces) do
    assert(M.id(name) and type(surface) == 'table'
      and vim.tbl_contains({ 'api', 'versioned', 'help' }, surface.kind), '无效的适配显示面')
    assert(surface.kind ~= 'versioned' or (type(surface.modules) == 'table' and next(surface.modules)),
      '版本接缝缺少模块证据')
    for module, path in pairs(surface.modules or {}) do
      assert(M.id(module:lower()) and fs.relative(path):match('^lua/.+%.lua$'), '无效的模块来源')
      assert(not paths[module] or paths[module] == path, '模块来源冲突')
      paths[module] = path
    end
  end
  for name, target in pairs(spec.targets) do
    assert(M.id(name) and M.version(target.neovim) and type(target.commit) == 'string'
      and #target.commit == 40 and target.commit:match('^[a-f0-9]+$') and type(target.sources) == 'table',
      '无效的目标版本')
    for name, sum in pairs(target.sources) do
      fs.relative(name)
      assert(M.digest(sum), '无效的目标文件摘要')
    end
  end
  for source, names in pairs(spec.help or {}) do
    assert(fs.relative(source):match('^doc/[%w_.%-]+%.txt$') and vim.islist(names) and #names > 0,
      '无效的 Help 来源')
    local prefix = 'help/' .. vim.fs.basename(source) .. '/doc/'
    assert(files[prefix .. 'tags-cn'], '缺少 Help 索引')
    for _, name in ipairs(names) do
      assert(type(name) == 'string' and name:match('^[%w_.%-]+%.cnx$') and files[prefix .. name], '缺少中文 Help')
    end
    for _, target in pairs(spec.targets) do
      assert(target.sources[source], 'Help 缺少上游版本证据')
    end
  end
  assert(not spec.source_projection or files['adapter/entry.lua'], '源码投影缺少适配入口')
  if not files['adapter/entry.lua'] then
    for _, surface in pairs(spec.surfaces) do
      assert(surface.kind == 'help' and not surface.modules, '数据包仅声明 Help 接缝')
    end
  end
end

local function prepare(manifest, files, allow_lua)
  assert(type(manifest) == 'table' and manifest.schema == 1 and manifest.sdk == 1
    and M.id(manifest.id) and M.version(manifest.version) and manifest.locale == 'zh_CN'
    and M.id(manifest.domain), '汉化包的格式、版本或语言不受支持')
  assert(type(files) == 'table' and type(manifest.files) == 'table', '无效的文件清单')
  assert(not manifest.executable or (M.id(manifest.executable) and not manifest.adapter), '无效的工具包标识')
  fs.index_id(manifest.files)
  for name, info in pairs(manifest.files) do
    local bytes = files[name]
    assert(type(bytes) == 'string' and #bytes == info.size and fs.utf8(bytes)
      and vim.fn.sha256(bytes) == info.sha256, '包文件校验失败：' .. name)
  end
  local tags = {}
  for name in pairs(files) do
    assert(manifest.files[name], '包中存在未声明的文件')
    local help = name:match('^help/[%w_.%-]+/doc/([%w_.%-]+)$')
    assert(name == 'catalogs/zh_CN.json' or name == 'adapter/entry.lua'
      or (help and (help == 'tags-cn' or help:match('%.cnx$'))), '非法的包文件：' .. name)
    if name:match('/tags%-cn$') then
      for line in files[name]:gmatch('[^\n]+') do
        local tag, file, address = line:match('^([^\t]+)\t([%w_.%-]+%.cnx)\t(.+)$')
        assert(tag and not tags[tag] and address == '/*' .. tag .. '*'
          and files[vim.fs.dirname(name) .. '/' .. file], '无效或重复的 Help 索引')
        tags[tag] = true
      end
    end
  end
  validate_spec(manifest, files)
  local source
  if files['catalogs/zh_CN.json'] then
    source = vim.json.decode(files['catalogs/zh_CN.json'])
    assert(source.locale == 'zh_CN', '词库语言不匹配')
    require('nvim-zh.catalog').prepare_sources({ [manifest.domain] = source })
  end
  local entry = files['adapter/entry.lua']
  if entry then
    assert(allow_lua, '此来源的 Lua 入口需要明确授权')
    assert(entry:byte() ~= 27 and loadstring(entry), '适配入口必须是可解析的 Lua 源码')
  end
  return { manifest = manifest, catalog = source, entry = entry, tags = tags }
end

function M.stage(bytes, expected, allow_lua)
  local sum = vim.fn.sha256(bytes)
  if expected then
    assert(sum == expected.sha256 and #bytes == expected.size, '发布附件摘要或大小不匹配')
  end
  local value = vim.json.decode(bytes)
  local manifest, files = value.manifest, value.files
  local candidate = prepare(manifest, files, allow_lua)
  if expected then
    assert(manifest.id == expected.id and manifest.version == expected.version, '发布索引与包信息不匹配')
  end
  local base = root() .. '/snapshots'
  fs.mkdir(base)
  local destination = base .. '/' .. sum
  if not uv.fs_stat(destination) then
    local stage = fs.unique(base .. '/stage')
    local ok, err = pcall(function()
      for name, data in pairs(files) do fs.write(stage .. '/' .. name, data) end
      fs.write(stage .. '/artifact.json', bytes)
      local renamed, why = uv.fs_rename(stage, destination)
      assert(renamed or uv.fs_stat(destination), why)
    end)
    if uv.fs_stat(stage) then vim.fn.delete(stage, 'rf') end
    if not ok then error(err, 0) end
  end
  local checked = M.load(manifest.id, { version = manifest.version, sha256 = sum, allow_lua = allow_lua })
  return checked, sum
end

function M.load(id, record)
  local folder = root() .. '/snapshots/' .. assert(M.digest(record.sha256))
  local bytes = fs.read(folder .. '/artifact.json', M.limit)
  assert(vim.fn.sha256(bytes) == record.sha256, '已存包摘要不匹配')
  local value = vim.json.decode(bytes)
  assert(value.manifest.id == id and value.manifest.version == record.version, '包登记与内容不匹配')
  local files = fs.verify(folder, value.manifest.files)
  local candidate = prepare(value.manifest, files, record.allow_lua)
  candidate.root = folder
  return candidate
end

return M
