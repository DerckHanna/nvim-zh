local M = {}

function M.new(current)
  local undo = {}
  local scope = { active = true }

  function scope.defer(release)
    assert(scope.active and type(release) == 'function', 'invalid adapter release')
    undo[#undo + 1] = release
  end

  function scope.wrap(object, key, factory)
    local original = object[key]
    assert(type(original) == 'function', 'unsupported adapter function ' .. tostring(key))
    local project = factory(original)
    assert(type(project) == 'function', 'adapter wrapper must return a function')
    local wrapper
    wrapper = function(...)
      if scope.active and current() and object[key] == wrapper then return project(...) end
      return original(...)
    end
    scope.defer(function()
      if object[key] == wrapper then object[key] = original end
    end)
    object[key] = wrapper
    return function() return scope.active and current() and object[key] == wrapper end
  end

  function scope.autocmd(event, options)
    assert(type(options.callback) == 'function', 'adapter event needs a callback')
    local opts = vim.tbl_extend('force', options, {
      callback = function(...)
        if scope.active and current() then return options.callback(...) end
      end,
    })
    local id = vim.api.nvim_create_autocmd(event, opts)
    scope.defer(function() pcall(vim.api.nvim_del_autocmd, id) end)
    return id
  end

  function scope.close()
    if not scope.active then return end
    scope.active = false
    local first
    for i = #undo, 1, -1 do
      local ok, err = pcall(undo[i])
      if not ok and not first then first = err end
    end
    undo = {}
    if first then error(first, 0) end
  end

  return scope
end

function M.adapter(spec, handlers)
  local entry, records = {}, {}

  function entry.attach(ctx)
    for _, name in ipairs(vim.fn.sort(vim.tbl_keys(handlers))) do
      local handler = handlers[name]
      local verified, reason = ctx.verify(name)
      local module = package.loaded[handler.module]
      local record = records[name]
      local applicable = type(module) == 'table' and verified ~= nil
      if record and record.scope and (not applicable or not rawequal(record.module, module)) then
        record.scope.close()
        records[name] = nil
        record = nil
      end
      if not record or not record.scope then
        local target, waiting
        if applicable then
          local ok
          ok, target, waiting = pcall(handler.probe, module)
          if not ok then
            records[name] = { reason = 'attach_failed', error = tostring(target) }
            target, waiting = nil, 'attach_failed'
          end
        end
        local scope
        if target then
          scope = M.new(function()
            return ctx.enabled() and rawequal(package.loaded[handler.module], module)
          end)
          scope.translate = function(context, text) return ctx.translate(spec.domain, context, text) end
          local ok, ownership = pcall(handler.mount, scope, target)
          if ok and (ownership == nil or type(ownership) == 'function') then
            records[name] = { scope = scope, module = module, owns = ownership }
          else
            pcall(scope.close)
            records[name] = { reason = 'attach_failed', error = tostring(ownership) }
          end
        elseif waiting ~= 'attach_failed' then
          records[name] = { reason = type(module) ~= 'table' and 'not_loaded' or reason
            or waiting or 'unsupported_api' }
        end
      end
    end
  end

  function entry.info()
    local result = { active = false, seam = 'declared adapter surfaces', reason = 'not_loaded', slots = {} }
    for name, record in pairs(records) do
      local active = record.scope ~= nil and (not record.owns or record.owns())
      result.slots[name] = { active = active, reason = record.reason or not active and 'external_override' or nil,
        error = record.error }
      result.active = active or result.active
      if not active and record.reason then result.reason = record.reason end
    end
    if result.active then result.reason = 'attached' end
    return result
  end

  function entry.detach()
    local old = records
    records = {}
    for _, record in pairs(old) do
      if record.scope then pcall(record.scope.close) end
    end
  end

  return entry
end

return M
