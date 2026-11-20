local M = {}
local fs = require('nvim-zh.fs')
local paths = require('nvim-zh.paths')
local config = require('nvim-zh.config')
local status = { status = 'unread', path = paths.config() }
local last_good = {}
local pending

local function bounds(value, depth, count)
  assert(depth <= 12, '配置嵌套过深')
  if type(value) == 'table' then
    for key, child in pairs(value) do
      count.n = count.n + 1
      assert(count.n <= 12000, '配置条目过多')
      assert(type(key) == 'string' or type(key) == 'number', '非法配置键')
      bounds(child, depth + 1, count)
    end
  elseif type(value) == 'string' then
    assert(#value <= 65536 and not value:find('\0', 1, true), '非法配置文本')
    assert(fs.utf8(value), '配置不是有效 UTF-8')
  else
    assert(type(value) == 'boolean' or (type(value) == 'number' and value == value
      and math.abs(value) < 1e9), '配置包含不支持的值')
  end
end

function M.resolve(base)
  pending = nil
  local ok, result = pcall(function()
    local layer = {}
    if fs.fingerprint(paths.config()) ~= 'absent' then
      layer = fs.json(paths.config(), 512 * 1024)
      assert(type(layer) == 'table' and layer.schema == 1, '本地配置需要 schema: 1')
      bounds(layer, 0, { n = 0 })
      layer.schema = nil
      assert(layer.pack_sources == nil, '汉化包发布源通过 Lua setup 配置')
    end
    local effective = config.resolve(config.merge(base, layer))
    pending = layer
    status = { status = 'ok', path = paths.config(), present = fs.fingerprint(paths.config()) ~= 'absent' }
    return effective
  end)
  if ok then return result end
  status = { status = 'error', path = paths.config(), error = tostring(result) }
  return config.resolve(config.merge(base, last_good))
end

function M.info() return vim.deepcopy(status) end
function M.commit()
  if pending then last_good = pending; pending = nil end
end
function M.reject(reason)
  pending = nil
  status = { status = 'error', path = paths.config(), error = tostring(reason) }
end
function M.fingerprint() return fs.fingerprint(paths.config()) end
return M
