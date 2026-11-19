local dap = require('dap')
local state = require('dap-view.state')
local session
local focused
local original_session = dap.session
local original_sessions = dap.sessions
local original_set_session = dap.set_session
local original_notify = vim.notify

DvEvents = {}
DvNotices = {}
vim.notify = function(message, level, opts)
  DvNotices[#DvNotices + 1] = { message = message, level = level, opts = opts }
  return original_notify(message, level, opts)
end

function DvFixture(mode)
  if mode == 'off' then
    dap.session, dap.sessions, dap.set_session = original_session, original_sessions, original_set_session
    state.threads_error = nil
    return
  end

  local path = vim.fn.getcwd() .. '/main.cpp'
  local frame = { id = 11, name = 'No active session', line = 7, column = 1, source = { path = path } }
  local other_frame = { id = 12, name = 'Local', line = 8, column = 1, source = { path = path } }
  local scope = { name = 'Local', expensive = false, variablesReference = 100 }
  local variable = { name = 'General Purpose Registers', value = 'No active session', variablesReference = 0 }
  frame.scopes = { scope }
  session = {
    id = 1, config = { type = 'fixture', name = 'No active session' }, adapter = { type = 'executable', command = 'echo' },
    current_frame = frame, stopped_thread_id = 1, children = {}, initialized = true,
    threads = { [1] = { id = 1, name = 'fixture thread', frames = { frame, other_frame } } },
    capabilities = {
      supportsCompletionsRequest = true, supportsSetVariable = true,
      supportsSetExpression = true, supportsExceptionFilterOptions = true,
    },
  }
  focused = session
  DvSession = session
  dap.session = function() return focused end
  dap.sessions = function() return {
    session,
    { id = 2, config = { type = 'fixture', name = 'Local' }, children = {} },
  } end
  dap.set_session = function(new_session) focused = new_session end
  session._frame_set = function(_, selected)
    DvEvents.frame = selected.id
  end
  session.request = function(_, command, args, cb)
    DvEvents[command] = args
    local err, response
    if command == 'completions' then
      if DvCompletionError then
        err = { message = 'No active session' }
      else
        response = { targets = { { label = 'Answer' }, { label = 'Another' } } }
      end
    elseif command == 'setVariable' or command == 'setExpression' then
      if DvSetError then
        err = { message = 'No active session' }
      else
        variable.value = args.value
        response = { value = args.value }
      end
      if DvSetDeferred then
        local thread = coroutine.running()
        if DvDisableDuringSet then
          vim.defer_fn(function() require('nvim-zh').teardown() end, 10)
        end
        vim.defer_fn(function() assert(coroutine.resume(thread, err, response)) end, 40)
        return coroutine.yield()
      end
    elseif command == 'variables' then
      response = { variables = mode == 'no_variables' and {} or { variable } }
    elseif command == 'evaluate' then
      if DvEvaluateError then
        err = { message = 'No active session' }
      elseif args.context == 'clipboard' then
        response = { result = 'No active session', variablesReference = 0 }
      elseif args.expression == 'Tree' then
        response = { result = 'tree', variablesReference = 100 }
      else
        response = { result = 'eval:' .. args.expression, variablesReference = 0 }
      end
    end
    if cb then
      vim.defer_fn(function() cb(err, response) end, 5)
    else
      return err, response
    end
  end

  if mode == 'running' then session.stopped_thread_id, session.current_frame = nil, nil end
  if mode == 'no_scopes' then frame.scopes = nil end
  if mode == 'expensive' then scope.expensive = true end
  if mode == 'no_threads' then session.threads = {} end
  if mode == 'multiple_threads' then
    session.threads[2] = { id = 2, name = 'worker No active session', frames = {
      { id = 21, name = 'worker_frame', line = 9, column = 1, source = { path = path } },
    } }
  end
  if mode == 'wrong_adapter' then session.config.type = 'codelldb' end
  if mode == 'missing_file' then
    local threads = require('dap-view.threads.view')
    threads.show()
    state.frame_paths_by_frame_id[frame.id] = '/invalid/No active session.cpp'
  end

  state.current_adapter = session.config.type
  state.exception_filter_options_by_adapter[state.current_adapter] = {}
  state.exceptions_options[state.current_adapter] = mode == 'no_exceptions' and {} or {
    { enabled = true, exception_filter = {
      filter = 'cpp_throw', label = 'C++: on throw', supportsCondition = true,
      description = 'No active session', conditionDescription = 'No active session',
    } },
    { enabled = false, exception_filter = { filter = 'unconditional', label = 'Local' } },
  }
end
