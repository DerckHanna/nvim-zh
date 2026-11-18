local M = {}

-- Validate the tables and sentinel before passing an MO to libc/gettext.
function M.validate(bytes, probe)
  local little = bytes:sub(1, 4) == '\222\018\004\149'
  assert(little or bytes:sub(1, 4) == '\149\004\018\222', '无效 MO magic')
  local function number(offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    assert(d, 'MO 表越界')
    if not little then a, b, c, d = d, c, b, a end
    return a + b * 256 + c * 65536 + d * 16777216
  end
  assert(#bytes >= 28 and number(4) < 65536, '不支持的 MO 版本')
  local count, originals, translations = number(8), number(12), number(16)
  assert(count > 0 and count <= 50000 and originals >= 28 and translations >= 28
    and originals + count * 8 <= #bytes and translations + count * 8 <= #bytes, 'MO 索引越界')
  local function text(table_start, index)
    local length, offset = number(table_start + index * 8), number(table_start + index * 8 + 4)
    assert(offset >= 28 and offset + length < #bytes and bytes:byte(offset + length + 1) == 0, 'MO 文本越界')
    local value = bytes:sub(offset + 1, offset + length)
    assert(require('nvim-zh.fs').utf8(value), 'MO 文本不是有效 UTF-8')
    return value
  end
  local previous, found
  for index = 0, count - 1 do
    local original, translation = text(originals, index), text(translations, index)
    assert(not previous or original > previous, 'MO 查询键未排序或重复')
    if original == probe.msgid then found = translation == probe.msgstr end
    previous = original
  end
  assert(found, 'MO 与资源清单中的译文探针不匹配')
end
return M
