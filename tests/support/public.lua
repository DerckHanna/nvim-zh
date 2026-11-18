local M = {}
function M.refresh()
  local result
  local id = require('nvim-zh').refresh(function(value) result = value end)
  assert(vim.wait(10000, function() return result ~= nil end, 10), 'refresh callback timed out')
  assert(result.task_id == id and result.ok, vim.inspect(result))
  assert(result.status == 'ok' or result.status == 'degraded', vim.inspect(result))
  return result
end
return M
