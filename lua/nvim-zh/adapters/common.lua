local M = {}
local engine = require('nvim-zh.engine')

function M.pack(...) return { n = select('#', ...), ... } end

function M.copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end

function M.translate(domain, context, text)
  if type(text) ~= 'string' or text == '' then return text end
  local ok, translated = pcall(engine.translate, {
    domain = domain,
    context = context,
    msgid = text,
    formatted = true,
  })
  if ok and type(translated) == 'string' then return translated end
  return text
end

-- Install one owned function wrapper. Adapters separately handle module-table
-- generations; this helper deliberately treats same-module replacement as an
-- external override and never reclaims it.
function M.wrap(state, key, get, set, factory)
  local record = state[key]
  local current = get()
  if record then
    if current == record.wrapper then
      record.active, record.reason = true, nil
    else
      record.active, record.reason = false, 'external_override'
      record.external = current
    end
    return record.active
  end
  if type(current) ~= 'function' then
    state[key] = { active = false, reason = 'unsupported_api' }
    return false
  end
  local wrapper = factory(current)
  record = { get = get, set = set, original = current, wrapper = wrapper, active = true }
  state[key] = record
  set(wrapper)
  return true
end

function M.unwrap(state, key, reason)
  local record = state[key]
  if not record then return end
  if record.wrapper then
    if record.get() == record.wrapper then
      record.set(record.original)
      state[key] = nil
    else
      record.active, record.reason = false, 'external_override'
    end
  else
    record.active = false
    record.reason = reason or 'disabled'
  end
end

function M.active(state, key)
  local record = state[key]
  return record ~= nil and record.active == true
end

function M.reason(state, key)
  local record = state[key]
  return record and record.reason or 'not_initialized'
end

return M
