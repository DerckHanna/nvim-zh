local M = {}
local uv = vim.uv
local serial = 0

function M.safe(path)
  local current = path
  while current and current ~= '' do
    local stat = uv.fs_lstat(current)
    assert(not stat or stat.type ~= 'link', '拒绝符号链接：' .. current)
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return path
end

function M.read(path, limit)
  M.safe(path)
  local stat = assert(uv.fs_stat(path), '无法读取：' .. path)
  assert(stat.type == 'file' and stat.size <= (limit or 8 * 1024 * 1024), '文件类型或大小不符合要求：' .. path)
  local fd = assert(uv.fs_open(path, 'r', 0))
  local ok, data = pcall(uv.fs_read, fd, stat.size, 0)
  uv.fs_close(fd)
  assert(ok and data and #data == stat.size, '读取失败：' .. path)
  return data
end

function M.json(path, limit)
  local text = M.read(path, limit)
  assert(M.utf8(text), '文件不是有效 UTF-8：' .. path)
  return vim.json.decode(text, { luanil = { object = false, array = false } })
end

function M.utf8(text)
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte < 128 then i = i + 1
    else
      local n, low, high
      if byte >= 194 and byte <= 223 then n, low, high = 1, 128, 191
      elseif byte >= 224 and byte <= 239 then
        n, low, high = 2, byte == 224 and 160 or 128, byte == 237 and 159 or 191
      elseif byte >= 240 and byte <= 244 then
        n, low, high = 3, byte == 240 and 144 or 128, byte == 244 and 143 or 191
      else return false end
      local second = text:byte(i + 1)
      if not second or second < low or second > high then return false end
      for offset = 2, n do
        local char = text:byte(i + offset)
        if not char or char < 128 or char > 191 then return false end
      end
      i = i + n + 1
    end
  end
  return true
end

function M.mkdir(path)
  M.safe(path)
  local stat = uv.fs_stat(path)
  if not stat then
    -- mkdir(..., 'p') can fail on an intermediate EEXIST when two fresh
    -- sessions create the same data tree. Ensure each parent first, then
    -- accept a competing mkdir only after verifying the resulting directory.
    local parent = vim.fs.dirname(path)
    if parent and parent ~= path then M.mkdir(parent) end
    local ok, why = uv.fs_mkdir(path, 448)
    stat = uv.fs_stat(path)
    assert(stat and stat.type == 'directory', why or ('不是目录：' .. path))
  else
    assert(stat.type == 'directory', '不是目录：' .. path)
  end
  M.safe(path)
end

function M.unique(path)
  serial = serial + 1
  return path .. '.' .. uv.os_getpid() .. '.' .. tostring(uv.hrtime()) .. '.' .. serial
end

function M.write(path, data)
  M.mkdir(vim.fs.dirname(path))
  M.safe(path)
  local tmp = M.unique(path)
  local fd = assert(uv.fs_open(tmp, 'wx', 384))
  local ok, err = pcall(function()
    assert(uv.fs_write(fd, data, 0) == #data, '写入不完整')
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then uv.fs_unlink(tmp); error(err, 0) end
  local renamed, why = uv.fs_rename(tmp, path)
  if not renamed then uv.fs_unlink(tmp); error(why, 0) end
end

function M.fingerprint(path)
  local s = uv.fs_lstat(path)
  return s and table.concat({ s.type, s.size, s.ino or 0, s.mtime.sec, s.mtime.nsec }, ':') or 'absent'
end

function M.relative(name)
  assert(type(name) == 'string' and #name < 240 and name:match('^[%w_./%-]+$')
    and name:sub(1, 1) ~= '/' and not name:find('..', 1, true) and not name:find('//', 1, true), '非法资源路径')
  return name
end

function M.index_id(files)
  local keys, parts = vim.tbl_keys(files), {}
  table.sort(keys)
  for _, key in ipairs(keys) do
    M.relative(key)
    local item = files[key]
    assert(type(item) == 'table' and type(item.sha256) == 'string' and #item.sha256 == 64
      and item.sha256:match('^[a-f0-9]+$') and type(item.size) == 'number'
      and item.size > 0 and item.size <= 8 * 1024 * 1024 and item.size % 1 == 0, '非法资源清单项')
    parts[#parts + 1] = key .. '\0' .. item.sha256 .. '\0' .. tostring(item.size) .. '\n'
  end
  assert(#keys > 0 and #keys <= 500, '资源清单数量不符合要求')
  return vim.fn.sha256(table.concat(parts))
end

function M.verify(root, files)
  local data, total = {}, 0
  M.index_id(files)
  for name, item in pairs(files) do
    total = total + item.size
    assert(total <= 32 * 1024 * 1024, '资源集过大')
    local bytes = M.read(root .. '/' .. name)
    assert(#bytes == item.size and vim.fn.sha256(bytes) == item.sha256, '资源校验失败：' .. name)
    data[name] = bytes
  end
  return data
end

return M
