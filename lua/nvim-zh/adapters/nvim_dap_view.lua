local engine = require('nvim-zh.engine')
local pack = require('nvim-zh.adapters.common').pack
local spec = require('nvim-zh.adapters.index')['nvim-dap-view']
local ui_source = debug.getinfo(require('nvim-zh.ui').setup, 'S').source
local unpack = table.unpack or unpack

local M = {}
local context
local generations = {}
local configs = setmetatable({}, { __mode = 'k' })
local mappings = setmetatable({}, { __mode = 'k' })
local jump_options = setmetatable({}, { __mode = 'k' })

-- Each substitution is anchored to a unique expression on the indicated line
-- of verified upstream bytes. Run the original rendering and callbacks with
-- localized display operands, including private functions reached by DAP.
local edits = {
  ["dap-view.actions"] = {
    { 68, [=["Failed to create nvim-dap-view buffer"]=],
      [=[dapzh.text("assertion", "Failed to create nvim-dap-view buffer")]=] },
    { 145, [=["Failed to create nvim-dap-view window"]=],
      [=[dapzh.text("assertion", "Failed to create nvim-dap-view window")]=] },
    { 193, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
    { 196, [=[#default_message]=],
      [=[vim.fn.strdisplaywidth(default_message)]=] },
    { 244, [=["Can't jump to unconfigured view: " .. view]=],
      [=[dapzh.text("notification", "Can't jump to unconfigured view: %s", view)]=] },
    { 251, [=["Can't jump to view: couldn't find the window"]=],
      [=[dapzh.text("notification", "Can't jump to view: couldn't find the window")]=] },
    { 258, [=["Can't show unconfigured view: " .. view]=],
      [=[dapzh.text("notification", "Can't show unconfigured view: %s", view)]=] },
    { 266, [=["Can't show view: couldn't find the window"]=],
      [=[dapzh.text("notification", "Can't show view: couldn't find the window")]=] },
    { 286, [=["Can't navigate within views: couldn't find the window"]=],
      [=[dapzh.text("notification", "Can't navigate within views: couldn't find the window")]=] },
    { 293, [=["Can't navigate within sessions: no session running"]=],
      [=[dapzh.text("notification", "Can't navigate within sessions: no session running")]=] },
    { 302, [=["Can't navigate: couldn't find the current object"]=],
      [=[dapzh.text("notification", "Can't navigate: couldn't find the current object")]=] },
  },
  ["dap-view.breakpoints.view"] = {
    { 26, [=["No breakpoints"]=],
      [=[dapzh.text("panel_message", "No breakpoints")]=] },
    { 54, [=["Separator length must not exceeed 1 character"]=],
      [=[dapzh.text("assertion", "Separator length must not exceeed 1 character")]=] },
  },
  ["dap-view.complete"] = {
    { 51, [=["completions request failed: " .. err.message]=],
      [=[dapzh.text("notification", "completions request failed: %s", err.message)]=] },
  },
  ["dap-view.console.view"] = {
    { 49, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
    { 61, [=["No terminal for the current session"]=],
      [=[dapzh.text("panel_message", "No terminal for the current session")]=] },
    { 220, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 249, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
  },
  ["dap-view.exceptions.actions"] = {
    { 24, [=["Condition not supported"]=],
      [=[dapzh.text("notification", "Condition not supported")]=] },
    { 31, [=["Condition: "]=],
      [=[dapzh.text("prompt", "Condition: ")]=] },
    { 54, [=["Condition not supported"]=],
      [=[dapzh.text("notification", "Condition not supported")]=] },
  },
  ["dap-view.exceptions.view"] = {
    { 17, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
    { 23, [=["Not supported by the debug adapter"]=],
      [=[dapzh.text("panel_message", "Not supported by the debug adapter")]=] },
    { 52, [=[string.format("\tExample: %s", filter.conditionDescription)]=],
      [=[dapzh.text("panel_message", "\tExample: %s", filter.conditionDescription)]=] },
    { 57, [=[filter.label]=],
      [=[dapzh.exception_label(dap.session(), filter)]=] },
    -- "wrap" is not a valid virt_lines_overflow value in Neovim 0.12.6.
    { 82, [=[virt_lines_overflow = "wrap"]=],
      [=[virt_lines_overflow = "scroll"]=] },
  },
  ["dap-view.guard"] = {
    { 9, [=["No active session"]=],
      [=[dapzh.text("notification", "No active session")]=] },
    { 15, [=["No stopped thread"]=],
      [=[dapzh.text("notification", "No stopped thread")]=] },
  },
  ["dap-view.hover"] = {
    { 39, [=["close"]=],
      [=[dapzh.text("mapping", "close")]=] },
    { 54, [=["toggle"]=],
      [=[dapzh.text("mapping", "toggle")]=] },
    { 60, [=["jump to parent"]=],
      [=[dapzh.text("mapping", "jump to parent")]=] },
    { 76, [=["set value"]=],
      [=[dapzh.text("mapping", "set value")]=] },
  },
  ["dap-view.hover.actions"] = {
    { 20, [=["New value: "]=],
      [=[dapzh.text("prompt", "New value: ")]=] },
    { 40, [=["New value: "]=],
      [=[dapzh.text("prompt", "New value: ")]=] },
    { 86, [=["Nothing to expand"]=],
      [=[dapzh.text("notification", "Nothing to expand")]=] },
  },
  ["dap-view.hover.eval"] = {
    { 13, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
  },
  ["dap-view.hover.view"] = {
    { 105, [=["has hover"]=],
      [=[dapzh.text("assertion", "has hover")]=] },
    { 106, [=["has hover state"]=],
      [=[dapzh.text("assertion", "has hover state")]=] },
    { 108, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
  },
  ["dap-view.options.winbar"] = {
    { 27, [=["Couldn't set the buffer for " .. view .. " view"]=],
      [=[dapzh.text("notification", "Couldn't set the buffer for %s view", view)]=] },
    { 56, [=[vim.notify_once("View '" .. view .. "' not found"]=],
      [=[dapzh.notify_once("View '" .. view .. "' not found", dapzh.text("notification", "View '%s' not found", view)]=] },
    { 108, [=[vim.notify_once("View '" .. view .. "' not found, skipping setup"]=],
      [=[dapzh.notify_once("View '" .. view .. "' not found, skipping setup", dapzh.text("notification", "View '%s' not found, skipping setup", view)]=] },
    { 118, [=[desc = desc]=],
      [=[desc = dapzh.label(setup.config, view, desc)]=] },
    { 166, [=[.. label ..]=],
      [=[.. dapzh.label(setup.config, v, label, true) ..]=] },
  },
  ["dap-view.scopes.actions"] = {
    { 22, [=["New value: "]=],
      [=[dapzh.text("prompt", "New value: ")]=] },
    { 86, [=["Nothing to expand"]=],
      [=[dapzh.text("notification", "Nothing to expand")]=] },
  },
  ["dap-view.scopes.view"] = {
    { 52, [=[variable.name]=],
      [=[dapzh.register_name(session, parent_path, variables_reference, variable)]=] },
    { 93, [=[#variable.name]=],
      [=[#variable_name]=] },
    { 113, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
    { 123, [=["Session not stopped"]=],
      [=[dapzh.text("panel_message", "Session not stopped")]=] },
    { 133, [=["No scopes for the current frame"]=],
      [=[dapzh.text("panel_message", "No scopes for the current frame")]=] },
    { 147, [=["No eligible scopes returned from adapter"]=],
      [=[dapzh.text("panel_message", "No eligible scopes returned from adapter")]=] },
    { 177, [=[scope.name]=],
      [=[dapzh.scope_name(session, scope)]=] },
    { 208, [=["No variables returned from adapter"]=],
      [=[dapzh.text("panel_message", "No variables returned from adapter")]=] },
  },
  ["dap-view.sessions.actions"] = {
    { 12, [=["No session under the cursor"]=],
      [=[dapzh.text("notification", "No session under the cursor")]=] },
  },
  ["dap-view.sessions.view"] = {
    { 47, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
  },
  ["dap-view.setup"] = {
    { 3, [=[require("dap-view.config").config]=],
      [=[dapzh.default_config(require("dap-view.config").config)]=] },
    { 7, [=[vim.tbl_deep_extend("force", M.config, config or {})]=],
      [=[dapzh.config(M.config, vim.tbl_deep_extend("force", M.config, config or {}), config)]=] },
  },
  ["dap-view.setup.validate"] = {
    { 23, [=["Unknown auto_toggle option: " .. config.auto_toggle]=],
      [=[dapzh.text("validation", "Unknown auto_toggle option: %s", config.auto_toggle)]=] },
  },
  ["dap-view.setup.validate.util"] = {
    { 23, [=[path .. "." .. err]=],
      [=[dapzh.validation_error(path, err, tbl)]=] },
    { 29, [=[path .. "." .. k .. ": unexpected field found in configuration"]=],
      [=[dapzh.text("validation", "%s.%s: unexpected field found in configuration", path, k)]=] },
  },
  ["dap-view.setup.validate.winbar"] = {
    { 84, [=["There must be at least one section"]=],
      [=[dapzh.text("validation", "There must be at least one section")]=] },
    { 87, [=["Separators table must contain at most 2 elements"]=],
      [=[dapzh.text("validation", "Separators table must contain at most 2 elements")]=] },
    { 91, [=["Default section (" .. default .. ") not listed as one of the sections " .. pretty_sections]=],
      [=[dapzh.text("validation", "Default section (%s) not listed as one of the sections %s", default, pretty_sections)]=] },
  },
  ["dap-view.threads.actions"] = {
    { 27, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 31, [=["Can only jump to a frame"]=],
      [=[dapzh.text("notification", "Can only jump to a frame")]=] },
  },
  ["dap-view.threads.keymaps"] = {
    { 18, [=["Filter: "]=],
      [=[dapzh.text("prompt", "Filter: ")]=] },
  },
  ["dap-view.threads.view"] = {
    { 29, [=["No active session"]=],
      [=[dapzh.text("panel_message", "No active session")]=] },
    { 38, [=["No stopped thread"]=],
      [=[dapzh.text("panel_message", "No stopped thread")]=] },
    { 42, [=["Debug adapter returned no threads"]=],
      [=[dapzh.text("panel_message", "Debug adapter returned no threads")]=] },
    { 160, [=["Separator length must not exceeed 1 character"]=],
      [=[dapzh.text("assertion", "Separator length must not exceeed 1 character")]=] },
  },
  ["dap-view.views"] = {
    { 12, [=["has nvim-dap-view window"]=],
      [=[dapzh.text("assertion", "has nvim-dap-view window")]=] },
    { 13, [=["has nvim-dap-view buffer"]=],
      [=[dapzh.text("assertion", "has nvim-dap-view buffer")]=] },
  },
  ["dap-view.views.keymaps"] = {
    { 14, [=["go to next view"]=],
      [=[dapzh.text("mapping", "go to next view")]=] },
    { 18, [=["go to prev view"]=],
      [=[dapzh.text("mapping", "go to prev view")]=] },
    { 22, [=["jump to last view"]=],
      [=[dapzh.text("mapping", "jump to last view")]=] },
    { 26, [=["jump to first view"]=],
      [=[dapzh.text("mapping", "jump to first view")]=] },
    { 30, [=["show help"]=],
      [=[dapzh.text("mapping", "show help")]=] },
  },
  ["dap-view.views.keymaps.help"] = {
    { 15, [=[math.floor(vim.go.columns * 0.4)]=],
      [=[dapzh.help_width(math.floor(vim.go.columns * 0.4))]=] },
    { 23, [=[setup.config.help.border]=],
      [=[dapzh.help_border(setup.config.help.border)]=] },
    { 25, [=["Default Keymaps"]=],
      [=[dapzh.text("help_title", "Default Keymaps")]=] },
    { 80, [=[create_win(#split_content)]=],
      [=[create_win(dapzh.help_height(#split_content))]=] },
    { 84, [=["close"]=],
      [=[dapzh.text("mapping", "close")]=] },
    { 86, [=[split_content)]=],
      [=[dapzh.help_lines(split_content, help_win))]=] },
  },
  ["dap-view.views.set"] = {
    { 10, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 18, [=["Failed to set variable " .. name .. " to value " .. value]=],
      [=[dapzh.text("notification", "Failed to set variable %s to value %s", name, value)]=] },
    { 22, [=["Adapter doesn't support `setVariable` request"]=],
      [=[dapzh.text("notification", "Adapter doesn't support `setVariable` request")]=] },
    { 30, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 40, [=["Failed to set expression " .. expr .. " to value " .. value]=],
      [=[dapzh.text("notification", "Failed to set expression %s to value %s", expr, value)]=] },
    { 49, [=["Adapter doesn't support `setExpression` request"]=],
      [=[dapzh.text("notification", "Adapter doesn't support `setExpression` request")]=] },
    { 63, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 88, [=["Can't set value for " .. variable_name .. " because it lacks an `evaluateName`"]=],
      [=[dapzh.text("notification", "Can't set value for %s because it lacks an `evaluateName`", variable_name)]=] },
    { 93, [=["Adapter lacks support for both `setExpression` and `setVariable` requests"]=],
      [=[dapzh.text("notification", "Adapter lacks support for both `setExpression` and `setVariable` requests")]=] },
  },
  ["dap-view.views.util"] = {
    { 16, [=["File not found: " .. abs_path]=],
      [=[dapzh.text("notification", "File not found: %s", abs_path)]=] },
    { 107, [=[keymaps[k].desc]=],
      [=[dapzh.mapping(keymaps[k])]=] },
  },
  ["dap-view.views.windows"] = {
    { 50, [=["Specify jump behavior: "]=],
      [=[dapzh.text("prompt", "Specify jump behavior: ")]=] },
    { 53, [=[return item.label]=],
      [=[return dapzh.jump_label(item, switchbuf.switchbuf_winfn)]=] },
  },
  ["dap-view.virtual-text"] = {
    { 74, [=["has frame"]=],
      [=[dapzh.text("assertion", "has frame")]=] },
  },
  ["dap-view.watches.actions"] = {
    { 58, [=["No expression under the under cursor"]=],
      [=[dapzh.text("notification", "No expression under the under cursor")]=] },
    { 77, [=["Missing `evaluateName`, can't copy variable"]=],
      [=[dapzh.text("notification", "Missing `evaluateName`, can't copy variable")]=] },
    { 80, [=["No expression or variable under the under cursor"]=],
      [=[dapzh.text("notification", "No expression or variable under the under cursor")]=] },
    { 105, [=["No expression or variable under the under cursor"]=],
      [=[dapzh.text("notification", "No expression or variable under the under cursor")]=] },
    { 134, [=["New value: "]=],
      [=[dapzh.text("prompt", "New value: ")]=] },
    { 169, [=["Expression: "]=],
      [=[dapzh.text("prompt", "Expression: ")]=] },
    { 212, [=["Nothing to expand"]=],
      [=[dapzh.text("notification", "Nothing to expand")]=] },
    { 215, [=["No expression or variable under the under cursor"]=],
      [=[dapzh.text("notification", "No expression or variable under the under cursor")]=] },
  },
  ["dap-view.watches.eval"] = {
    { 9, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 66, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
    { 79, [=["Variable " .. expr .. " copied to clipboard"]=],
      [=[dapzh.text("notification", "Variable %s copied to clipboard", expr)]=] },
    { 83, [=["Adapter doesn't support clipboard evaluation"]=],
      [=[dapzh.text("notification", "Adapter doesn't support clipboard evaluation")]=] },
    { 90, [=["has active session"]=],
      [=[dapzh.text("assertion", "has active session")]=] },
  },
  ["dap-view.watches.keymaps"] = {
    { 6, [=["Expression: "]=],
      [=[dapzh.text("prompt", "Expression: ")]=] },
  },
  ["dap-view.watches.view"] = {
    { 85, [=["No expressions"]=],
      [=[dapzh.text("panel_message", "No expressions")]=] },
  },
}

local default_labels = {
  breakpoints = 'Breakpoints', scopes = 'Scopes', exceptions = 'Exceptions', watches = 'Watches',
  threads = 'Threads', repl = 'REPL', sessions = 'Sessions', console = 'Console',
}
local scopes = { Local = true, Static = true, Global = true, Registers = true }
local register_groups = {
  ['General Purpose Registers'] = true,
  ['Floating Point Registers'] = true,
  ['Advanced Vector Extensions'] = true,
}
local exception_labels = { cpp_throw = 'C++: on throw', cpp_catch = 'C++: on catch' }

local function lookup(kind, msgid, ...)
  local ok, translated, status = pcall(engine.translate, {
    domain = spec.domain, context = kind, msgid = msgid, args = { ... },
  })
  if ok and status == 'translated' then return translated end
  if select('#', ...) > 0 then return string.format(msgid, ...) end
  return msgid
end

local function field(value, key)
  return type(value) == 'table' and rawget(value, key) or nil
end

local function remember_config(previous, merged, supplied)
  local labels = configs[previous]
  if not labels then return merged end
  local explicit = field(field(supplied, 'winbar'), 'base_sections')
  local retained = {}
  for id in pairs(labels) do
    if field(field(explicit, id), 'label') == nil then retained[id] = true end
  end
  configs[merged] = retained
  return merged
end

local function codelldb(session)
  if not session or not session.config or session.config.type ~= 'codelldb' then return false end
  local adapter = session.adapter
  if not adapter then return false end
  local executable = adapter.type == 'executable' and adapter or adapter.executable
  local command = executable and executable.command
  if type(command) ~= 'string' then return false end
  local resolved = vim.fn.exepath(command)
  if resolved == '' then return false end
  local actual = vim.uv.fs_realpath(resolved) or resolved
  return vim.fs.basename(actual):lower():gsub('%.exe$', '') == 'codelldb'
end

local function notify_once(original, display, ...)
  if original == display then return vim.notify_once(original, ...) end
  local notify, once = vim.notify, vim.notify_once
  local source = type(once) == 'function' and debug.getinfo(once, 'S').source
  if source ~= 'vim/_core/editor' and source ~= ui_source then
    return once(original, ...)
  end

  -- Keep the original key in Neovim's once cache. Replace the display operand
  -- only during its synchronous dispatch, and release the hook before calling
  -- the notification provider so reentrant notifications retain their source.
  local dispatch
  dispatch = function(message, ...)
    local caller = debug.getinfo(2, 'S')
    if message == original and vim.notify == dispatch and caller and caller.source == 'vim/_core/editor' then
      vim.notify = notify
      return notify(display, ...)
    end
    return notify(message, ...)
  end
  vim.notify = dispatch
  local results = pack(pcall(once, original, ...))
  if vim.notify == dispatch then vim.notify = notify end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local function projector(is_current)
  local function enabled()
    return context and context.enabled() and is_current()
  end
  local function text(kind, msgid, ...)
    if enabled() then return lookup(kind, msgid, ...) end
    if select('#', ...) > 0 then return string.format(msgid, ...) end
    return msgid
  end

  return {
    text = text,
    notify_once = notify_once,
    default_config = function(config)
      configs[config] = default_labels
      return config
    end,
    config = remember_config,
    label = function(config, id, label, statusline)
      local winbar = config.winbar
      if enabled() and configs[config] and configs[config][id] and label == default_labels[id]
          and not winbar.custom_sections[id] and context.verify('titles') then
        local translated = lookup('section', label)
        return statusline and (translated:gsub('%%', '%%%%')) or translated
      end
      return label
    end,
    mapping = function(mapping)
      local origin = mappings[mapping]
      if origin and origin.current() and origin.desc == mapping.desc and origin.action == mapping.action then
        return text('mapping', origin.desc)
      end
      return mapping.desc
    end,
    jump_label = function(item, options)
      local origin = jump_options[options]
      if item.label == 'custom' or (origin and origin.current() and origin.options[item.label] == item.cb) then
        return text('jump_option', item.label)
      end
      return item.label
    end,
    help_width = function(width)
      return enabled() and math.max(1, math.min(vim.go.columns - 4, math.max(44, width))) or width
    end,
    help_border = function(border)
      if enabled() and border == nil and vim.o.winborder == '' then return 'single' end
      return border
    end,
    help_height = function(height)
      return enabled() and math.max(1, math.min(vim.go.lines - 4, height)) or height
    end,
    help_lines = function(lines, win)
      if not enabled() then return lines end
      vim.wo[win][0].wrap = true
      vim.wo[win][0].linebreak = true
      vim.wo[win][0].breakindent = true
      return vim.tbl_map(function(line) return lookup('help_line', line) end, lines)
    end,
    validation_error = function(path, err, fields)
      local original = path .. '.' .. err
      if not enabled() or type(err) ~= 'string' then return original end
      -- vim.validate raises at its caller. Keep this position and render the
      -- configuration path beside the field name.
      local location, detail = err:match('^(.-validate/util%.lua:11): (.*)$')
      local key, expected, actual = (detail or err):match('^([^:]+): expected ([%a|]+), got (%a+)$')
      local field_spec = key and fields[key]
      if not field_spec or type(field_spec[1]) ~= actual then return original end
      local validator = field_spec[2]
      if type(validator) == 'table' then validator = table.concat(validator, '|') end
      if expected ~= validator then return original end
      local display = lookup('validation', '%s: expected %s, got %s', path .. '.' .. key, expected, actual)
      return location and (display .. ' (' .. location .. ')') or display
    end,
    scope_name = function(session, scope)
      if enabled() and scopes[scope.name] and codelldb(session) then
        return lookup('codelldb_scope', scope.name)
      end
      return scope.name
    end,
    register_name = function(session, parent, reference, variable)
      if enabled() and parent == 'Registers' and register_groups[variable.name] and variable.type == nil
          and variable.variablesReference > 0 and codelldb(session) then
        for _, scope in ipairs(session.current_frame and session.current_frame.scopes or {}) do
          if scope.name == parent and scope.variablesReference == reference then
            return lookup('codelldb_register', variable.name)
          end
        end
      end
      return variable.name
    end,
    exception_label = function(session, filter)
      if enabled() and filter.label == exception_labels[filter.filter] and codelldb(session) then
        for _, capability in ipairs(session.capabilities.exceptionBreakpointFilters or {}) do
          if rawequal(capability, filter) then return lookup('codelldb_exception', filter.label) end
        end
      end
      return filter.label
    end,
  }
end

local function replace(line, before, after)
  local start, finish = line:find(before, 1, true)
  assert(start and not line:find(before, finish + 1, true), 'ambiguous dap-view source projection')
  return line:sub(1, start - 1) .. after .. line:sub(finish + 1)
end

function M.project_source(module, bytes, path, current)
  local lines = vim.split(bytes, '\n', { plain = true })
  local owners, object = {}, nil
  local projection = function()
    if not current() then return false end
    for field, value in pairs(owners) do
      if object[field] ~= value then return false end
    end
    return true
  end
  for _, edit in ipairs(edits[module] or {}) do
    local row, before, after = unpack(edit)
    lines[row] = replace(lines[row], before, after)
  end
  -- A single-line prelude leaves all error locations at upstream line numbers.
  local chunk = assert(loadstring('return function(dapzh, ...) ' .. table.concat(lines, '\n') .. '\nend', '@' .. path))()
  local runtime = projector(projection)
  return function(...)
    object = chunk(runtime, ...)
    for key, value in pairs(object) do
      if type(value) == 'function' then owners[key] = value end
    end
    if module:match('%.keymaps$') then
      for _, mapping in pairs(object) do
        if type(mapping) == 'table' and type(mapping.desc) == 'string' then
          mappings[mapping] = { current = projection, desc = mapping.desc, action = mapping.action }
        end
      end
    elseif module == 'dap-view.views.windows.switchbuf' then
      local options = object.switchbuf_winfn
      jump_options[options] = { current = projection, options = vim.tbl_extend('force', {}, options) }
    end
    generations[module] = projection
    return object
  end
end

function M.attach(ctx) context = ctx end
function M.detach() context = nil end

function M.info(ctx)
  local slots = {}
  local active = false
  for surface, rule in pairs(spec.surfaces) do
    if rule.kind == 'versioned' and ctx.verify(surface) then
      local owned = true
      for module in pairs(rule.modules) do
        if package.loaded[module] and not (generations[module] and generations[module]()) then
          owned = false
          break
        end
      end
      slots[surface] = { active = owned, reason = not owned and 'external_override' or nil }
      active = active or owned
    end
  end
  return { active = active, seam = 'verified source display projections', slots = slots }
end

return M
