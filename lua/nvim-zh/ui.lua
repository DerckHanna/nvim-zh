local M = {}

local DOMAIN = 'nvim-ui'
local engine = require('nvim-zh.engine')
local records = {}
local sources = {}
local config = { notify = false, prompts = false, select_items = false, echo = false }
local translating_notify = false

local function translate(text, context, domain)
  if type(text) ~= 'string' or text == '' then return text end
  local ok, translated = pcall(engine.translate, {
    domain = domain or DOMAIN,
    context = context or '',
    msgid = text,
    formatted = true,
  })
  if ok and type(translated) == 'string' then return translated end
  return text
end

local function translate_notification(msg, opts)
  if type(msg) ~= 'string' or msg == '' then return msg end
  local route = type(opts) == 'table' and type(opts.title) == 'string' and sources[opts.title] or nil
  if route and route.matches then
    local ok, matched = pcall(route.matches, opts)
    if not ok or not matched then return msg end
  end
  local domain, context = DOMAIN, ''
  local prefix
  if route then domain, context, prefix = route.domain, route.context, route.prefix end
  if prefix and msg:sub(1, #prefix) == prefix then
    local rest = msg:sub(#prefix + 1)
    local whitespace, body = rest:match('^(%s*)(.*)$')
    return prefix .. whitespace .. translate(body, context, domain)
  end
  return translate(msg, context, domain)
end

local function current(record)
  return record.get()
end

local function restore(name)
  local record = records[name]
  if not record or not record.wrapper then return end
  if current(record) == record.wrapper then
    record.set(record.original)
    record.wrapper = nil
    record.original = nil
    record.external = nil
    record.active = false
    record.reason = 'disabled'
  else
    record.active = false
    record.external = current(record)
    record.reason = 'external_override'
  end
end

local function install(name, get, set, factory)
  local record = records[name]
  if record and record.wrapper then
    if get() == record.wrapper then
      record.active = true
      record.reason = nil
      return
    end
    record.active = false
    record.external = get()
    record.reason = 'external_override'
    return
  end
  if record and record.external and get() == record.external then
    record.active = false
    record.reason = 'external_override'
    return
  end
  local original = get()
  if type(original) ~= 'function' then
    records[name] = { get = get, set = set, active = false, reason = 'not_a_function' }
    return
  end
  local wrapper = factory(original)
  records[name] = {
    get = get,
    set = set,
    original = original,
    wrapper = wrapper,
    active = true,
  }
  set(wrapper)
end

local function install_notify()
  install('notify', function() return vim.notify end, function(value) vim.notify = value end, function(original)
    return function(msg, level, opts)
      if not config.notify then return original(msg, level, opts) end
      if translating_notify then return original(msg, level, opts) end
      translating_notify = true
      local translated = translate_notification(msg, opts)
      translating_notify = false
      return original(translated, level, opts)
    end
  end)
  install('notify_once', function() return vim.notify_once end, function(value) vim.notify_once = value end, function(original)
    -- Neovim 0.12.6 notify_once deduplicates msg before dispatching to vim.notify.
    -- https://neovim.io/doc/user/lua.html#vim.notify_once()
    -- Keep msg unchanged here so translated text and dynamic values never become dedup keys.
    return function(msg, level, opts)
      return original(msg, level, opts)
    end
  end)
end

local function display_opts(opts, context)
  if type(opts) ~= 'table' then return opts end
  local copy = {}
  for key, value in pairs(opts) do copy[key] = value end
  if type(copy.prompt) == 'string' then copy.prompt = translate(copy.prompt, context) end
  if type(copy.title) == 'string' then copy.title = translate(copy.title, context) end
  return copy
end

local function install_prompts()
  install('input', function() return vim.ui.input end, function(value) vim.ui.input = value end, function(original)
    return function(opts, on_confirm)
      if not config.prompts then return original(opts, on_confirm) end
      return original(display_opts(opts, 'input'), on_confirm)
    end
  end)
  install('select', function() return vim.ui.select end, function(value) vim.ui.select = value end, function(original)
    return function(items, opts, on_choice)
      if not config.prompts then return original(items, opts, on_choice) end
      local copy = display_opts(opts, 'select')
      if config.select_items and type(copy) == 'table'
        and (copy.format_item == nil or type(copy.format_item) == 'function') then
        local format_item = copy.format_item or tostring
        copy.format_item = function(item)
          local text = format_item(item)
          if not config.prompts or not config.select_items then return text end
          return translate(text, 'select_item')
        end
      end
      return original(items, copy, on_choice)
    end
  end)
end


local function echo_chunks(chunks)
  if type(chunks) ~= 'table' then return chunks end
  local copy = {}
  for key, chunk in pairs(chunks) do
    if type(chunk) == 'table' and type(chunk[1]) == 'string' then
      local chunk_copy = {}
      for chunk_key, value in pairs(chunk) do chunk_copy[chunk_key] = value end
      chunk_copy[1] = translate(chunk[1], 'echo')
      copy[key] = chunk_copy
    else
      copy[key] = chunk
    end
  end
  return copy
end

local function install_echo()
  install('echo', function() return vim.api.nvim_echo end, function(value) vim.api.nvim_echo = value end, function(original)
    return function(chunks, history, opts)
      if not config.echo then return original(chunks, history, opts) end
      -- nvim_echo is not API-fast; pass through without loading catalogs or doing IO.
      -- https://neovim.io/doc/user/api.html#nvim_echo()
      if type(vim.in_fast_event) == 'function' and vim.in_fast_event() then
        return original(chunks, history, opts)
      end
      return original(echo_chunks(chunks), history, opts)
    end
  end)
end

-- Internal adapter API: route only an exact public notification title to a
-- domain. Unknown titles always remain in nvim-ui; no text-based provenance
-- guessing or global fuzzy replacement is involved.
function M.register_source(spec)
  assert(type(spec) == 'table' and type(spec.title) == 'string' and spec.title ~= '',
    'notification source title must be a non-empty string')
  assert(type(spec.domain) == 'string' and spec.domain:match('^[%w][%w_.%-]*$'),
    'notification source domain is invalid')
  assert(spec.context == nil or type(spec.context) == 'string', 'notification source context must be string')
  assert(spec.prefix == nil or (type(spec.prefix) == 'string' and spec.prefix ~= ''),
    'notification source prefix must be a non-empty string')
  assert(spec.matches == nil or type(spec.matches) == 'function', 'invalid notification source matcher')
  assert(sources[spec.title] == nil, 'notification source already registered: ' .. spec.title)
  local record = { title = spec.title, domain = spec.domain, context = spec.context or '',
    prefix = spec.prefix, matches = spec.matches }
  sources[spec.title] = record
  local released = false
  return function()
    if released then return end
    released = true
    if sources[spec.title] == record then sources[spec.title] = nil end
  end
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  if config.notify then
    install_notify()
  else
    restore('notify_once')
    restore('notify')
  end
  if config.prompts then
    install_prompts()
  else
    restore('input')
    restore('select')
  end
  if config.echo then
    install_echo()
  else
    restore('echo')
  end
end

function M.teardown()
  config = { notify = false, prompts = false, select_items = false, echo = false }
  sources = {}
  restore('notify_once')
  restore('notify')
  restore('input')
  restore('select')
  restore('echo')
end

function M.info()
  local result = { enabled = vim.deepcopy(config) }
  for _, name in ipairs({ 'notify', 'notify_once', 'input', 'select', 'echo' }) do
    local record = records[name]
    result[name] = {
      enabled = (name == 'notify' or name == 'notify_once') and config.notify == true
        or (name == 'input' or name == 'select') and config.prompts == true
        or name == 'echo' and config.echo == true,
      active = record ~= nil and record.active == true,
      reason = record and record.reason or 'not_initialized',
    }
  end
  local select = records.select
  result.select_items = {
    enabled = config.select_items == true,
    active = config.prompts == true and config.select_items == true and select ~= nil and select.active == true,
    reason = not config.select_items and 'disabled' or not config.prompts and 'prompts_disabled'
      or select and select.reason or 'not_initialized',
  }
  result.sources = {}
  for _, route in pairs(sources) do
    result.sources[#result.sources + 1] = { title = route.title, domain = route.domain, context = route.context }
  end
  table.sort(result.sources, function(a, b) return a.title < b.title end)
  return result
end


return M
