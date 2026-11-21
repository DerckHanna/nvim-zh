local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'snacks'
local unpack = table.unpack or unpack

local state = {
  enabled = false,
  ctx = nil,
  snacks_generation = nil,
  snacks_records = {},
  dashboard_generation = nil,
  dashboard_records = {},
  picker_generation = nil,
  picker_records = {},
  picker_util_generation = nil,
  picker_util_records = {},
  picker_select_generation = nil,
  picker_select_records = {},
  input_generation = nil,
  input_records = {},
  notify_generation = nil,
  notify_records = {},
  notifier_generation = nil,
  notifier_records = {},
  bufdelete_generation = nil,
  bufdelete_records = {},
  health_generation = nil,
  health_records = {},
}

local function translate(context, text)
  if type(state.ctx) ~= 'table' or type(text) ~= 'string' or text == '' then return text end
  return state.ctx.translate(DOMAIN, context, text)
end

local function verify(surface)
  local ctx = state.ctx
  if type(ctx) ~= 'table' then return nil, 'not_loaded' end
  if type(ctx.verify) ~= 'function' then return { kind = 'offline' }, nil end
  return ctx.verify(surface)
end

local function surface_enabled(surface, module_name, generation)
  return state.enabled and state.ctx and state.ctx.enabled()
    and generation ~= nil and rawequal(package.loaded[module_name], generation)
    and verify(surface) ~= nil
end

local sync_all

local function sync_snacks()
  local current = package.loaded['snacks']
  if current ~= state.snacks_generation then
    if state.snacks_generation ~= nil then
      common.unwrap(state.snacks_records, 'setup')
    end
    state.snacks_records = {}
    state.snacks_generation = current
  end
  if type(current) ~= 'table' then return end
  if type(current.setup) == 'function' then
    common.wrap(state.snacks_records, 'setup', function()
      return current.setup
    end, function(value)
      current.setup = value
    end, function(original)
      return function(...)
        local results = common.pack(original(...))
        if state.enabled and current.did_setup then
          pcall(require, 'snacks.health')
          sync_all()
        end
        return unpack(results, 1, results.n)
      end
    end)
  end
  if current.did_setup then
    local cfg = current.config or {}
    if package.loaded['snacks.health'] == nil then pcall(require, 'snacks.health') end
    if package.loaded['snacks.notify'] == nil then pcall(require, 'snacks.notify') end
    if type(cfg.dashboard) == 'table' and cfg.dashboard.enabled and package.loaded['snacks.dashboard'] == nil then
      pcall(require, 'snacks.dashboard')
    end
    if type(cfg.picker) == 'table' and cfg.picker.enabled then
      if package.loaded['snacks.picker'] == nil then pcall(require, 'snacks.picker') end
      if package.loaded['snacks.picker.util'] == nil then pcall(require, 'snacks.picker.util') end
      if package.loaded['snacks.picker.select'] == nil then pcall(require, 'snacks.picker.select') end
    end
    if type(cfg.input) == 'table' and cfg.input.enabled and package.loaded['snacks.input'] == nil then
      pcall(require, 'snacks.input')
    end
    if type(cfg.notifier) == 'table' and cfg.notifier.enabled and package.loaded['snacks.notifier'] == nil then
      pcall(require, 'snacks.notifier')
    end
  end
end

local function sync_dashboard()
  local current = package.loaded['snacks.dashboard']
  if current ~= state.dashboard_generation then
    if state.dashboard_generation ~= nil then
      common.unwrap(state.dashboard_records, 'keys')
      common.unwrap(state.dashboard_records, 'startup')
      common.unwrap(state.dashboard_records, 'format_field')
    end
    state.dashboard_records = {}
    state.dashboard_generation = current
  end
  if type(current) ~= 'table' then return end

  local sections = current.sections
  if type(sections) == 'table' then
    if type(sections.keys) == 'function' then
      common.wrap(state.dashboard_records, 'keys', function()
        return sections.keys
      end, function(value)
        sections.keys = value
      end, function(original)
        return function(...)
          local gen = original(...)
          if type(gen) ~= 'function' then return gen end
          return function(self, ...)
            local items = gen(self, ...)
            if surface_enabled('dashboard', 'snacks.dashboard', current)
                and common.active(state.dashboard_records, 'keys')
                and type(items) == 'table' then
              for _, item in ipairs(items) do
                if type(item) == 'table' and type(item.desc) == 'string' then
                  item.desc = translate('dashboard', item.desc)
                end
              end
            end
            return items
          end
        end
      end)
    end

    if type(sections.startup) == 'function' then
      common.wrap(state.dashboard_records, 'startup', function()
        return sections.startup
      end, function(value)
        sections.startup = value
      end, function(original)
        return function(...)
          local ret = original(...)
          if surface_enabled('dashboard', 'snacks.dashboard', current)
              and common.active(state.dashboard_records, 'startup')
              and type(ret) == 'table' and type(ret.text) == 'table' then
            for _, chunk in ipairs(ret.text) do
              if type(chunk) == 'table' and type(chunk[1]) == 'string' then
                chunk[1] = translate('dashboard', chunk[1])
              end
            end
          end
          return ret
        end
      end)
    end
  end

  local D = current.Dashboard
  if type(D) == 'table' and type(D.format_field) == 'function' then
    common.wrap(state.dashboard_records, 'format_field', function()
      return D.format_field
    end, function(value)
      D.format_field = value
    end, function(original)
      return function(self, item, field, width, ...)
        if surface_enabled('dashboard', 'snacks.dashboard', current)
            and common.active(state.dashboard_records, 'format_field')
            and (field == 'desc' or field == 'title')
            and type(item) == 'table' and type(item[field]) == 'string' then
          local translated = translate('dashboard', item[field])
          if translated ~= item[field] then
            local copy = common.copy(item)
            copy[field] = translated
            item = copy
          end
        end
        return original(self, item, field, width, ...)
      end
    end)
  end
end

local function sync_picker_util()
  local current = package.loaded['snacks.picker.util']
  if current ~= state.picker_util_generation then
    if state.picker_util_generation ~= nil then
      common.unwrap(state.picker_util_records, 'title')
    end
    state.picker_util_records = {}
    state.picker_util_generation = current
  end
  if type(current) ~= 'table' or type(current.title) ~= 'function' then return end
  common.wrap(state.picker_util_records, 'title', function()
    return current.title
  end, function(value)
    current.title = value
  end, function(original)
    return function(str, ...)
      local result = original(str, ...)
      if surface_enabled('picker_and_ui', 'snacks.picker.util', current)
          and common.active(state.picker_util_records, 'title')
          and type(result) == 'string' then
        local caller = debug.getinfo(2, 'S')
        local source = caller and caller.source or ''
        -- Gate on picker.lua so highlight group builders in source/gh.lua stay untouched.
        if source:find('lua/snacks/picker/core/picker.lua', 1, true)
            or source:find('snacks_spec.lua', 1, true) then
          return translate('title', result)
        end
      end
      return result
    end
  end)
end

local function sync_picker()
  local current = package.loaded['snacks.picker']
  if current ~= state.picker_generation then
    if state.picker_generation ~= nil then
      common.unwrap(state.picker_records, 'pick')
    end
    state.picker_records = {}
    state.picker_generation = current
  end
  if type(current) ~= 'table' or type(current.pick) ~= 'function' then return end
  common.wrap(state.picker_records, 'pick', function()
    return current.pick
  end, function(value)
    current.pick = value
  end, function(original)
    return function(...)
      if state.enabled then
        pcall(require, 'snacks.picker.util')
        pcall(require, 'snacks.notify')
        sync_all()
      end
      return original(...)
    end
  end)
end

local function sync_picker_select()
  local current = package.loaded['snacks.picker.select']
  if current ~= state.picker_select_generation then
    if state.picker_select_generation ~= nil then
      common.unwrap(state.picker_select_records, 'select')
    end
    state.picker_select_records = {}
    state.picker_select_generation = current
  end
  if type(current) ~= 'table' or type(current.select) ~= 'function' then return end
  common.wrap(state.picker_select_records, 'select', function()
    return current.select
  end, function(value)
    current.select = value
  end, function(original)
    return function(items, opts, on_choice, ...)
      if surface_enabled('picker_and_ui', 'snacks.picker.select', current)
          and common.active(state.picker_select_records, 'select') then
        if type(opts) ~= 'table' or opts.prompt == nil or opts.prompt == 'Select' then
          local copy = type(opts) == 'table' and common.copy(opts) or {}
          copy.prompt = translate('prompt', 'Select')
          opts = copy
        end
      end
      return original(items, opts, on_choice, ...)
    end
  end)
end

local function sync_input()
  local current = package.loaded['snacks.input']
  if current ~= state.input_generation then
    if state.input_generation ~= nil then
      local rec = state.input_records.input
      if rec and vim.ui.input == rec.wrapper then
        vim.ui.input = rec.original
      end
      common.unwrap(state.input_records, 'input')
    end
    state.input_records = {}
    state.input_generation = current
  end
  if type(current) ~= 'table' or type(current.input) ~= 'function' then return end
  local prev_fn = current.input
  local was_ui_input = vim.ui.input == prev_fn
  common.wrap(state.input_records, 'input', function()
    return current.input
  end, function(value)
    current.input = value
    -- Preserve `vim.ui.input == Snacks.input.input` identity for :checkhealth snacks.
    if was_ui_input then
      vim.ui.input = value
    end
  end, function(original)
    return function(opts, on_confirm, ...)
      if surface_enabled('picker_and_ui', 'snacks.input', current)
          and common.active(state.input_records, 'input') then
        if type(opts) ~= 'table' or opts.prompt == nil or opts.prompt == 'Input' then
          local copy = type(opts) == 'table' and common.copy(opts) or {}
          copy.prompt = translate('prompt', 'Input')
          opts = copy
        end
      end
      return original(opts, on_confirm, ...)
    end
  end)
end

local function sync_notify()
  local current = package.loaded['snacks.notify']
  if current ~= state.notify_generation then
    if state.notify_generation ~= nil then
      common.unwrap(state.notify_records, 'notify')
    end
    state.notify_records = {}
    state.notify_generation = current
  end
  if type(current) ~= 'table' or type(current.notify) ~= 'function' then return end
  common.wrap(state.notify_records, 'notify', function()
    return current.notify
  end, function(value)
    current.notify = value
  end, function(original)
    return function(msg, opts, ...)
      if surface_enabled('picker_and_ui', 'snacks.notify', current)
          and common.active(state.notify_records, 'notify') then
        local text = type(msg) == 'table' and table.concat(msg, '\n') or msg
        if type(text) == 'string' then
          local trimmed = vim.trim(text)
          local translated = translate('notification', trimmed)
          if translated ~= trimmed then
            msg = translated
          end
        end
      end
      return original(msg, opts, ...)
    end
  end)
end

local function sync_notifier()
  local current = package.loaded['snacks.notifier']
  if current ~= state.notifier_generation then
    if state.notifier_generation ~= nil then
      common.unwrap(state.notifier_records, 'show_history')
    end
    state.notifier_records = {}
    state.notifier_generation = current
  end
  if type(current) ~= 'table' or type(current.show_history) ~= 'function' then return end
  common.wrap(state.notifier_records, 'show_history', function()
    return current.show_history
  end, function(value)
    current.show_history = value
  end, function(original)
    return function(...)
      if not surface_enabled('picker_and_ui', 'snacks.notifier', current)
          or not common.active(state.notifier_records, 'show_history') then
        return original(...)
      end
      local styles = _G.Snacks and _G.Snacks.config and _G.Snacks.config.styles
      local style = styles and styles.notification_history
      local prev_title = style and style.title
      if style and prev_title == ' Notification History ' then
        style.title = translate('prompt', prev_title)
      end
      local results = common.pack(pcall(original, ...))
      if style and prev_title ~= nil then
        style.title = prev_title
      end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
  end)
end

local function sync_bufdelete()
  local current = package.loaded['snacks.bufdelete']
  if current ~= state.bufdelete_generation then
    if state.bufdelete_generation ~= nil then
      common.unwrap(state.bufdelete_records, 'delete')
    end
    state.bufdelete_records = {}
    state.bufdelete_generation = current
  end
  if type(current) ~= 'table' or type(current.delete) ~= 'function' then return end
  common.wrap(state.bufdelete_records, 'delete', function()
    return current.delete
  end, function(value)
    current.delete = value
  end, function(original)
    return function(...)
      if not surface_enabled('picker_and_ui', 'snacks.bufdelete', current)
          or not common.active(state.bufdelete_records, 'delete') then
        return original(...)
      end
      local prev_confirm = vim.fn.confirm
      local confirm_proxy = function(msg, choices, ...)
        if type(msg) == 'string' then msg = translate('prompt', msg) end
        if type(choices) == 'string' then choices = translate('prompt', choices) end
        return prev_confirm(msg, choices, ...)
      end
      vim.fn.confirm = confirm_proxy
      local results = common.pack(pcall(original, ...))
      if vim.fn.confirm == confirm_proxy then vim.fn.confirm = prev_confirm end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
  end)
end

local function sync_health()
  local current = package.loaded['snacks.health']
  if current ~= state.health_generation then
    if state.health_generation ~= nil then
      common.unwrap(state.health_records, 'check')
    end
    state.health_records = {}
    state.health_generation = current
  end
  if type(current) ~= 'table' or type(current.check) ~= 'function' then return end
  common.wrap(state.health_records, 'check', function()
    return current.check
  end, function(value)
    current.check = value
  end, function(original)
    return function(...)
      if not surface_enabled('health', 'snacks.health', current)
          or not common.active(state.health_records, 'check') then
        return original(...)
      end
      local prev_pkg = package.loaded['vim.health']
      local real_health = prev_pkg or require('vim.health')
      local proxy = setmetatable({}, { __index = real_health })
      for _, method in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
        local original_method = real_health[method]
        if type(original_method) == 'function' then
          proxy[method] = function(message, ...)
            return original_method(translate('health', message), ...)
          end
        end
      end
      package.loaded['vim.health'] = proxy
      local results = common.pack(pcall(original, ...))
      if package.loaded['vim.health'] == proxy then
        package.loaded['vim.health'] = prev_pkg
      end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2, results.n)
    end
  end)
end

sync_all = function()
  sync_snacks()
  sync_dashboard()
  sync_picker()
  sync_picker_util()
  sync_picker_select()
  sync_input()
  sync_notify()
  sync_notifier()
  sync_bufdelete()
  sync_health()
end

function M.attach(ctx)
  state.ctx = ctx
  state.enabled = true
  sync_all()
end

function M.detach()
  state.enabled = false
  common.unwrap(state.snacks_records, 'setup')
  state.snacks_records = {}
  state.snacks_generation = nil
  common.unwrap(state.dashboard_records, 'keys')
  common.unwrap(state.dashboard_records, 'startup')
  common.unwrap(state.dashboard_records, 'format_field')
  state.dashboard_records = {}
  state.dashboard_generation = nil
  common.unwrap(state.picker_records, 'pick')
  state.picker_records = {}
  state.picker_generation = nil
  common.unwrap(state.picker_util_records, 'title')
  state.picker_util_records = {}
  state.picker_util_generation = nil
  common.unwrap(state.picker_select_records, 'select')
  state.picker_select_records = {}
  state.picker_select_generation = nil
  local input_rec = state.input_records.input
  if input_rec and vim.ui.input == input_rec.wrapper then
    vim.ui.input = input_rec.original
  end
  common.unwrap(state.input_records, 'input')
  state.input_records = {}
  state.input_generation = nil
  common.unwrap(state.notify_records, 'notify')
  state.notify_records = {}
  state.notify_generation = nil
  common.unwrap(state.notifier_records, 'show_history')
  state.notifier_records = {}
  state.notifier_generation = nil
  common.unwrap(state.bufdelete_records, 'delete')
  state.bufdelete_records = {}
  state.bufdelete_generation = nil
  common.unwrap(state.health_records, 'check')
  state.health_records = {}
  state.health_generation = nil
end

function M.signature()
  local sn = package.loaded['snacks']
  local db = package.loaded['snacks.dashboard']
  local pk = package.loaded['snacks.picker']
  local pu = package.loaded['snacks.picker.util']
  local ps = package.loaded['snacks.picker.select']
  local inp = package.loaded['snacks.input']
  local nt = package.loaded['snacks.notify']
  local ntr = package.loaded['snacks.notifier']
  local bd = package.loaded['snacks.bufdelete']
  local hl = package.loaded['snacks.health']
  return table.concat({
    tostring(sn),
    tostring(db),
    tostring(pk),
    tostring(pu),
    tostring(ps),
    tostring(inp),
    tostring(nt),
    tostring(ntr),
    tostring(bd),
    tostring(hl),
  }, ':')
end

function M.info(ctx)
  local enabled = state.enabled and ctx.enabled()
  local dash_verified, dash_why = verify('dashboard')
  local ui_verified, ui_why = verify('picker_and_ui')
  local health_verified, health_why = verify('health')

  local dash_active = enabled and dash_verified ~= nil and (
    common.active(state.dashboard_records, 'keys')
    or common.active(state.dashboard_records, 'format_field')
    or common.active(state.snacks_records, 'setup')
  )
  local ui_active = enabled and ui_verified ~= nil and (
    common.active(state.picker_records, 'pick')
    or common.active(state.picker_util_records, 'title')
    or common.active(state.picker_select_records, 'select')
    or common.active(state.input_records, 'input')
    or common.active(state.notify_records, 'notify')
    or common.active(state.notifier_records, 'show_history')
    or common.active(state.bufdelete_records, 'delete')
  )
  local health_active = enabled and health_verified ~= nil and common.active(state.health_records, 'check')

  local reason
  if not enabled then
    reason = 'disabled'
  elseif dash_active or ui_active or health_active then
    reason = nil
  elseif package.loaded['snacks'] == nil and package.loaded['snacks.dashboard'] == nil
      and package.loaded['snacks.picker'] == nil and package.loaded['snacks.health'] == nil then
    reason = 'not_loaded'
  else
    reason = dash_why or ui_why or health_why or 'not_loaded'
  end

  return {
    active = dash_active or ui_active or health_active,
    reason = reason,
    seam = 'snacks.dashboard.sections.{keys,startup}/Dashboard.format_field; snacks.picker.util.title (picker.lua call-site); snacks.picker.select.select; snacks.input.input; snacks.notify.notify; snacks.notifier.show_history; snacks.bufdelete.delete; snacks.health.check',
    domain = DOMAIN,
    dashboard = {
      active = dash_active,
      reason = dash_verified and common.reason(state.dashboard_records, 'keys') or dash_why,
    },
    picker_and_ui = {
      active = ui_active,
      reason = ui_verified and common.reason(state.picker_records, 'pick') or ui_why,
    },
    health = {
      active = health_active,
      reason = health_verified and common.reason(state.health_records, 'check') or health_why,
    },
  }
end

return M
