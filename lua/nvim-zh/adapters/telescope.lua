local common = require('nvim-zh.adapters.common')

local M = {}

local DOMAIN = 'telescope'
local unpack = table.unpack or unpack
local attached = false
local ctx
local release_notification
local find_pre_group
local custom_titles = setmetatable({}, { __mode = 'k' })

-- The pinned build of the three internal builtins registers its select
-- callback through select_default:replace / action_set.select:replace_if. The
-- replacement functions are the only owners of these print calls, so their
-- definition site identifies them: file plus the function's first line inside
-- lua/telescope/builtin/__internal.lua at the pinned commit.
-- `__internal.lua` ends with `return apply_checks(internal)`, which replaces
-- EVERY builtin with a wrapper closure defined at that one site. At runtime
-- debug.getinfo(internal.planets).linedefined is therefore 1545 for all of them
-- (verified against the pinned commit), not the source line of the builtin or of
-- the print() call inside its replacement callback. Provenance is the
-- (source file, linedefined) pair: the pinned __internal.lua plus 1545.
-- The replacement callbacks are registered as `select_default:replace(function()
-- ... end)`; debug.getinfo(...).linedefined is the line of that anonymous
-- function expression (verified against the pinned commit).
local PRINT_OWNERS = {
  planets = { defined = 271 },
  filetypes = { defined = 1337 },
  -- `autocommands` registers through action_set.select:replace_if, not
  -- select_default, so its closure is covered by the action_set hook below.
  autocommands = { defined = 1435 },
}
local INTERNAL_SOURCE = 'lua/telescope/builtin/__internal.lua'
-- actions.which_key is defined at this line in the pinned actions/init.lua; the
-- popup.create call that builds its float is inside that function.
local WHICH_KEY_DEFINED = 1256
local ACTIONS_SOURCE = 'lua/telescope/actions/init.lua'

local slots = {
  window = {
    module = 'telescope.pickers.window',
    method = 'get_initial_window_options',
    surface = 'initial_titles',
    records = {},
  },
  previewer = {
    module = 'telescope.previewers.previewer',
    method = 'title',
    surface = 'preview_titles',
    records = {},
  },
  pickers = {
    module = 'telescope.pickers',
    method = 'new',
    records = {},
  },
  refine = {
    module = 'telescope.actions.generate',
    method = 'refine',
    surface = 'refine_titles',
    records = {},
  },
  which_key = {
    module = 'telescope.actions',
    action = 'which_key',
    surface = 'which_key_titles',
    records = {},
  },
  edit_register = {
    module = 'telescope.actions',
    action = 'edit_register',
    surface = 'input_prompts',
    records = {},
  },
  git_create_branch = {
    module = 'telescope.actions',
    action = 'git_create_branch',
    surface = 'input_prompts',
    records = {},
  },
  git_rename_branch = {
    module = 'telescope.actions',
    action = 'git_rename_branch',
    surface = 'input_prompts',
    records = {},
  },
  git_delete_branch = {
    module = 'telescope.actions',
    action = 'git_delete_branch',
    surface = 'input_prompts',
    records = {},
  },
  git_merge_branch = {
    module = 'telescope.actions',
    action = 'git_merge_branch',
    surface = 'input_prompts',
    records = {},
  },
  git_rebase_branch = {
    module = 'telescope.actions',
    action = 'git_rebase_branch',
    surface = 'input_prompts',
    records = {},
  },
  git_reset_mixed = {
    module = 'telescope.actions',
    action = 'git_reset_mixed',
    surface = 'input_prompts',
    records = {},
  },
  git_reset_soft = {
    module = 'telescope.actions',
    action = 'git_reset_soft',
    surface = 'input_prompts',
    records = {},
  },
  git_reset_hard = {
    module = 'telescope.actions',
    action = 'git_reset_hard',
    surface = 'input_prompts',
    records = {},
  },
  to_fuzzy_refine = {
    module = 'telescope.actions',
    action = 'to_fuzzy_refine',
    -- Refine has no surface of its own: this slot only exposes the moment the
    -- plugin loads actions/generate.lua so that seam can be attached.
    records = {},
  },
}

local ACTION_REQUIRE_SLOTS = { 'to_fuzzy_refine' }

local INPUT_ACTIONS = {
  'edit_register',
  'git_create_branch',
  'git_rename_branch',
  'git_delete_branch',
  'git_merge_branch',
  'git_rebase_branch',
  'git_reset_mixed',
  'git_reset_soft',
  'git_reset_hard',
}
local ACTION_SLOTS = vim.list_extend({ 'which_key' }, INPUT_ACTIONS)

for _, slot in pairs(slots) do
  slot.key = slot.action or slot.method
end

-- Set while the adapter is attached; the scoped builtin-output seam reads it.
local ACTION_OUTPUT_ENABLED = false

local function loaded_module(slot)
  return package.loaded[slot.module]
end

-- Installing a wrapper and projecting through it are separate decisions. The
-- wrapper is installed whenever the module generation matches and the owned
-- record is live; each projection additionally re-checks the pinned digest, so an
-- unverified revision keeps rendering the original text.
local function enabled(slot, generation)
  return attached and ctx and ctx.enabled() and slot.generation == generation
end

local function verified(slot)
  if not slot.surface then return true end
  if type(ctx) ~= 'table' or type(ctx.verify) ~= 'function' then return false end
  return ctx.verify(slot.surface) ~= nil
end

local function projecting(slot, generation)
  return enabled(slot, generation) and verified(slot)
end

local function title(text)
  return ctx.translate(DOMAIN, 'title', text)
end

local function tr(context, text)
  return ctx.translate(DOMAIN, context, text)
end

local sync

-- Source-provenance helper shared by the seams that must prove the calling
-- frame belongs to the pinned plugin source instead of a user callback.
local function frame_in(info, path, defined)
  if type(info) ~= 'table' then return false end
  local source = info.source
  if type(source) ~= 'string' or source:sub(1, 1) ~= '@' then return false end
  if source:sub(-#path - 1) ~= '/' .. path then return false end
  return defined == nil or info.linedefined == defined
end

local function caller_in(path, defined)
  -- The whole in-progress stack is inspected because the projection runs inside
  -- a wrapper: the plugin frame that owns the call can be at any depth. Only the
  -- pinned plugin source path can match, so this adapter's own frames never do.
  for level = 1, 16 do
    local info = debug.getinfo(level, 'S')
    if not info then return false end
    if frame_in(info, path, defined) then return true end
  end
  return false
end

-- Actions in telescope.actions are action objects: the callable metatable runs
-- `_func[name]`, and `replace()`/`enhance()` keep working only while the object
-- identity is untouched. Swapping the plain implementation inside `_func` keeps
-- that identity, so the display wrapper is installed there and the object itself
-- is never replaced. common.wrap's get/set contract still applies unchanged.
local function action_access(module, name)
  local object = type(module) == 'table' and module[name] or nil
  local metatable = type(object) == 'table' and getmetatable(object) or nil
  local functions = type(metatable) == 'table' and metatable._func or nil
  if type(functions) ~= 'table' or type(functions[name]) ~= 'function' then return nil end
  return {
    get = function() return functions[name] end,
    set = function(value) functions[name] = value end,
  }
end

-- Scoped vim.fn.input projection. Every owned prompt site is synchronous: the
-- pinned actions call vim.fn.input and consume its return value before doing
-- anything else, so the proxy exists only for that call. The prompt text is the
-- only projected value; the typed string, the default value and the argument
-- count cross the boundary unchanged, which is what keeps the `[Y/n]` helper's
-- lowercase comparison and the register edit comparison working.
local function with_input_prompt(slot, generation, fn, ...)
  if not projecting(slot, generation) or type(vim.fn.input) ~= 'function' then return fn(...) end
  local original_input = vim.fn.input
  local wrapper
  wrapper = function(prompt, ...)
    if not projecting(slot, generation) then return original_input(prompt, ...) end
    return original_input(tr('prompt', prompt), ...)
  end
  vim.fn.input = wrapper
  local results = common.pack(pcall(fn, ...))
  if vim.fn.input == wrapper then vim.fn.input = original_input end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- Scoped print projection. A bare print has no notify/echo route, so the only
-- owned route is the public entry that performs the printing. Each string
-- argument is looked up in the catalog; the catalog holds only the few fixed
-- forms these sites emit, so unknown text (and every non-string payload) passes
-- through byte-identically.
local function with_print(slot, generation, fn, ...)
  if not projecting(slot, generation) or type(_G.print) ~= 'function' then return fn(...) end
  local original_print = _G.print
  local wrapper
  wrapper = function(...)
    if not projecting(slot, generation) then return original_print(...) end
    local values = common.pack(...)
    for index = 1, values.n do
      if type(values[index]) == 'string' then values[index] = tr('print', values[index]) end
    end
    return original_print(unpack(values, 1, values.n))
  end
  _G.print = wrapper
  local results = common.pack(pcall(fn, ...))
  if _G.print == wrapper then _G.print = original_print end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

local factories = {}

function factories.window(original, generation)
  return function(...)
    local returns = common.pack(original(...))
    local slot = slots.window
    if not projecting(slot, generation) or type(returns[1]) ~= 'table' then
      return unpack(returns, 1, returns.n)
    end

    -- This fixed Telescope API constructs display-only window options. Project
    -- their titles without mutating the picker or the original returned tables.
    local projection = common.copy(returns[1])
    local custom = custom_titles[(...)] or {}
    for _, name in ipairs({ 'prompt', 'results', 'preview' }) do
      local section = returns[1][name]
      if type(section) == 'table' and not custom[name] then
        local copy = common.copy(section)
        copy.title = title(section.title)
        projection[name] = copy
      end
    end
    returns[1] = projection
    return unpack(returns, 1, returns.n)
  end
end

function factories.previewer(original, generation)
  return function(...)
    local returns = common.pack(original(...))
    if enabled(slots.previewer, generation) and type(returns[1]) == 'string' then
      returns[1] = title(returns[1])
    end
    return unpack(returns, 1, returns.n)
  end
end

-- actions.to_fuzzy_refine decides its prefix from the picker's INTERNAL English
-- prompt_title before it calls generate.refine, so that branch stays English.
-- generate.refine is a documented public function (actions/generate.lua) that
-- only forwards opts to border:change_title and picker:refresh; projecting the
-- display copies of prompt_title/results_title on a shallow copy therefore
-- changes the rendered border title and nothing else. The caller's table is
-- never mutated, so a user calling refine directly keeps their own values.
function factories.refine(original, generation)
  return function(prompt_bufnr, opts, ...)
    local slot = slots.refine
    if not projecting(slot, generation) or type(opts) ~= 'table' then
      return original(prompt_bufnr, opts, ...)
    end
    if type(opts.prompt_title) ~= 'string' and type(opts.results_title) ~= 'string' then
      return original(prompt_bufnr, opts, ...)
    end
    local projection = common.copy(opts)
    if type(projection.prompt_title) == 'string' then
      projection.prompt_title = title(projection.prompt_title)
    end
    if type(projection.results_title) == 'string' then
      projection.results_title = title(projection.results_title)
    end
    local returns = common.pack(pcall(original, prompt_bufnr, projection, ...))
    if not returns[1] then error(returns[2], 0) end
    return unpack(returns, 2, returns.n)
  end
end

-- The which_key float is built by a self-made plenary popup, so the only display
-- boundary is popup.create's options table. actions/init.lua requires
-- plenary.popup as a table (line 56) and calls `popup.create` (line 1393), so
-- replacing that one field for the duration of the wrapped call reaches the call
-- without claiming any plenary version: the plugin-owned pinned module is
-- actions/init.lua, and every non-matching caller keeps the original function.
local function which_key_projection(options)
  if type(options) ~= 'table' or options.noautocmd ~= true then return nil end
  local titles = options.title
  if type(titles) ~= 'table' or type(titles[1]) ~= 'table' then return nil end
  if type(titles[1].text) ~= 'string' or type(titles[1].pos) ~= 'string' then return nil end
  local translated = tr('which_key_title', titles[1].text)
  if translated == titles[1].text then return nil end
  if not caller_in(ACTIONS_SOURCE, WHICH_KEY_DEFINED) then return nil end
  local projection = common.copy(options)
  local first = common.copy(titles[1])
  first.text = translated
  projection.title = { first }
  for index = 2, #titles do projection.title[index] = titles[index] end
  return projection
end

function factories.which_key(original, generation)
  return function(prompt_bufnr, opts, ...)
    local slot = slots.which_key
    local popup = package.loaded['plenary.popup']
    if not projecting(slot, generation) or type(popup) ~= 'table'
      or type(popup.create) ~= 'function' then
      return original(prompt_bufnr, opts, ...)
    end
    local original_create = popup.create
    local wrapper
    wrapper = function(what, options, ...)
      if not projecting(slot, generation) then return original_create(what, options, ...) end
      local projection = which_key_projection(options)
      if projection == nil then return original_create(what, options, ...) end
      return original_create(what, projection, ...)
    end
    popup.create = wrapper
    local returns = common.pack(pcall(original, prompt_bufnr, opts, ...))
    if popup.create == wrapper then popup.create = original_create end
    if not returns[1] then error(returns[2], 0) end
    return unpack(returns, 2, returns.n)
  end
end

-- The register edit and the five branch confirmations are synchronous. The
-- delete branch action additionally prints one fixed progress line for every
-- deleted branch; pickers.lua:815-847 runs that callback inside the delete loop
-- before self:refresh(), so scoping print around the action covers it exactly.
local function prompt_factory(slot)
  return function(original, generation)
    return function(...)
      return with_input_prompt(slot, generation, original, ...)
    end
  end
end

function factories.git_delete_branch(original, generation)
  return function(...)
    local slot = slots.git_delete_branch
    local function delete(...)
      return with_input_prompt(slot, generation, original, ...)
    end
    return with_print(slot, generation, delete, ...)
  end
end

-- The three internal builtins register their select callback while pickers.new
-- runs, so the registration itself is the owned boundary: pickers.new is our
-- lifecycle slot, and a replacement function is wrapped only when its
-- definition site is the pinned internal builtin. A user attach_mappings that
-- calls select_default:replace(user_fn) never matches. After detach the retained
-- replacement is a pure pass-through because the wrapper re-checks `enabled`
-- before touching print; nothing relies on the next Picker:new clearing it.
local function owns_replacement(slot, value)
  local info = debug.getinfo(value, 'S')
  if not frame_in(info, INTERNAL_SOURCE, nil) then return false end
  for _, owner in pairs(PRINT_OWNERS) do
    if info.linedefined == owner.defined then return true end
  end
  return false
end

local function guard_print(slot, generation, value)
  return function(...)
    if not projecting(slot, generation) then return value(...) end
    return with_print(slot, generation, value, ...)
  end
end

local function projected_replacements(slot, generation, values)
  if type(values) ~= 'table' then return values end
  local projection, changed = {}, false
  for key, value in pairs(values) do
    if type(value) == 'function' and owns_replacement(slot, value) then
      projection[key] = guard_print(slot, generation, value)
      changed = true
    else
      projection[key] = value
    end
  end
  return changed and projection or values
end

-- Scoped print projection for the action-callback path. Unlike with_print it is
-- not tied to a single slot generation (the builtins that print are not slots);
-- its caller already verified attachment and catalog availability, and it is
-- restored on every exit path.
local function with_action_print(fn, ...)
  if type(_G.print) ~= 'function' then return fn(...) end
  local original_print = _G.print
  local wrapper
  wrapper = function(...)
    local values = common.pack(...)
    for index = 1, values.n do
      if type(values[index]) == 'string' then values[index] = tr('print', values[index]) end
    end
    return original_print(unpack(values, 1, values.n))
  end
  _G.print = wrapper
  local results = common.pack(pcall(fn, ...))
  if _G.print == wrapper then _G.print = original_print end
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- Scope the print projection to one public action invocation.
--
-- `internal.planets|filetypes|autocommands` print from a select_default
-- replacement callback that runs when the user presses <CR>, i.e. long after
-- pickers.new returned. The callback is reachable only through the public
-- action (actions.select_default / action_set.select), so wrapping that action's
-- *implementation* and installing the print proxy for the duration of the call
-- gives an owned, provenance-checked window without any permanent global hook.
-- print is restored on every exit path, and after detach the wrapper is inert
-- because it re-checks `projecting` before touching anything.
local function hook_action_print(slot, generation, module, name)
  local access = action_access(module, name)
  if not access then return end
  local original = access.get()
  if type(original) ~= 'function' then return end
  local wrapper
  wrapper = function(...)
    if not projecting(slot, generation) then return original(...) end
    return with_print(slot, generation, original, ...)
  end
  access.set(wrapper)
  return function()
    if access.get() == wrapper then access.set(original) end
  end
end

-- Wrap only plugin-owned print callbacks; the wrapped function installs the
-- scoped print projection for its own execution and is a pure pass-through when
-- the adapter is detached or the callback is not plugin-owned.
local function projected_print_replacements(values)
  if type(values) ~= 'table' then return values end
  local changed = false
  local projection = {}
  for key, value in pairs(values) do
    if type(value) == 'function' and owns_replacement(nil, value) then
      projection[key] = function(...) return with_action_print(value, ...) end
      changed = true
    else
      projection[key] = value
    end
  end
  return changed and projection or values
end

local function install_replacement_hooks(slot, generation)
  local installed = {}
  local function hook(module, name)
    local object = type(module) == 'table' and module[name] or nil
    local metatable = type(object) == 'table' and getmetatable(object) or nil
    if type(metatable) ~= 'table' or type(metatable.replace_map) ~= 'function' then return end
    local original = metatable.replace_map
    local wrapper
    wrapper = function(self, values, ...)
      if not projecting(slot, generation) then return original(self, values, ...) end
      return original(self, projected_replacements(slot, generation, values), ...)
    end
    metatable.replace_map = wrapper
    installed[#installed + 1] = { metatable = metatable, original = original, wrapper = wrapper }
  end
  hook(package.loaded['telescope.actions'], 'select_default')
  -- The three internal builtins print from their own select_default replacement
  -- callback, which the plugin registers inside Picker:find. Wrapping the stored
  -- replacement is not observable after the call returns, so the owned boundary
  -- is the public action invocation itself: scope the print projection to the
  -- execution of actions.select_default (and action_set.select), which is the
  -- only path those callbacks run through. Provenance is checked per print call
  -- against the pinned __internal.lua definition lines above.
  -- These action wrappers live on the module tables, so they are installed once
  -- per attached generation (see ensure_action_print_hooks) rather than once per
  -- picker; double wrapping would nest the print proxy.
  hook(package.loaded['telescope.actions.set'], 'select')
  return installed
end

local function release_replacement_hooks(installed)
  for _, record in ipairs(installed) do
    if rawget(record.metatable, 'replace_map') == record.wrapper then
      record.metatable.replace_map = record.original
    end
  end
end

-- Registering the callback happens inside Picker:find, which the public builtin
-- runs after pickers.new returns. The hook therefore stays installed for the
-- whole builtin call and is restored on every exit path.
function factories.pickers(original, generation)
  return function(...)
    local slot = slots.pickers
    local display = enabled(slot, generation)
    if display then
      -- Builtins normally load previewers immediately before pickers.new. Sync
      -- here so their initial title query and subsequent refresh both see the
      -- owned wrapper, without requiring an absent plugin module ourselves.
      sync(slots.window)
      sync(slots.previewer)
      for _, name in ipairs(ACTION_SLOTS) do sync(slots[name]) end
      for _, name in ipairs(ACTION_REQUIRE_SLOTS) do sync(slots[name]) end
      sync(slots.refine)
    end
    -- The replacement hook must be installed BEFORE pickers.new runs: the
    -- builtin reaches Picker:find (and therefore actions.select_default:replace)
    -- inside that call. Restore on every exit path.
    local hooks = display and install_replacement_hooks(slot, generation) or nil
    local returns = common.pack(pcall(original, ...))
    if hooks then release_replacement_hooks(hooks) end
    if not returns[1] then error(returns[2], 0) end
    local picker = returns[2]
    if enabled(slot, generation) then
      local opts = ...
      if type(picker) == 'table' and type(opts) == 'table' then
        custom_titles[picker] = {
          prompt = opts.prompt_title ~= nil, results = opts.results_title ~= nil,
          preview = opts.preview_title ~= nil,
        }
      end
      sync(slots.window)
      sync(slots.previewer)
    end
    return unpack(returns, 2, returns.n)
  end
end

slots.window.factory = factories.window
slots.previewer.factory = factories.previewer
slots.pickers.factory = factories.pickers
slots.refine.factory = factories.refine
slots.which_key.factory = factories.which_key
slots.git_delete_branch.factory = factories.git_delete_branch
for _, name in ipairs(ACTION_REQUIRE_SLOTS) do
  slots[name].factory = function(original, generation)
    return function(...)
      -- to_fuzzy_refine requires telescope.actions.generate on every branch; do
      -- it here so the refine seam is attached before refine is invoked.
      if attached and ctx and ctx.enabled() then
        pcall(require, 'telescope.actions.generate')
        sync(slots.refine)
      end
      return original(...)
    end
  end
end
-- Slots with their own seam keep it; the remaining public actions are plain
-- prompt owners (git_delete_branch also projects its progress print).
local ACTION_FACTORIES = { which_key = true, git_delete_branch = true }
for _, name in ipairs(ACTION_SLOTS) do
  if not ACTION_FACTORIES[name] then slots[name].factory = prompt_factory(slots[name]) end
end

sync = function(slot)
  local current = loaded_module(slot)
  if current ~= slot.generation then
    if slot.generation ~= nil then
      -- Invalidating a generation restores the previous wrapper before the new
      -- module table is adopted, so closures retained elsewhere become inert.
      local previous = slot.generation
      slot.generation = nil
      common.unwrap(slot.records, slot.key)
      slot.generation = previous
    end

    slot.records = {}
    slot.generation = current
    if type(current) ~= 'table' then
      if current ~= nil and current ~= false then
        slot.records[slot.key] = { active = false, reason = 'unsupported_api' }
      end
      return
    end
  end

  if type(current) ~= 'table' then return end
  local accessible = true
  if slot.action then
    local target = action_access(current, slot.action)
    slot.get, slot.set, accessible = target and target.get, target and target.set, target ~= nil
  else
    slot.get = function() return current[slot.method] end
    slot.set = function(value) current[slot.method] = value end
  end
  if slot.surface then
    local verified, reason = ctx.verify(slot.surface)
    if not verified then
      common.unwrap(slot.records, slot.key)
      slot.unavailable = reason
      return
    end
    slot.unavailable = nil
  end
  if not accessible then
    common.unwrap(slot.records, slot.key, 'unsupported_api')
    slot.unavailable = 'unsupported_api'
    return
  end
  -- common.wrap also handles reattaching after our owned wrapper was removed,
  -- repeated setup, and same-generation external replacement.
  common.wrap(slot.records, slot.key, slot.get, slot.set,
    function(original) return slot.factory(original, current) end)
end

local action_print_records = {}

-- The three internal builtins print from a callback registered through
-- select_default:replace()/action_set.select:replace_if(). `replace_*` stores that
-- callback in the action metatable's `_replacements` and `run_replace_or_original`
-- prefers `_replacements` over `_func`, so wrapping `_func` is never reached.
-- The owned boundary is therefore `replace_map`: it runs exactly when the plugin
-- (or a user) registers a replacement, and only callbacks whose definition site is
-- the pinned internal builtin at a known line are wrapped. Everything else is
-- stored untouched, so user attach_mappings keep working.
local function ensure_action_print_hooks()
  local targets = {
    { package.loaded['telescope.actions'], 'select_default' },
    { package.loaded['telescope.actions.set'], 'select' },
  }
  for _, target in ipairs(targets) do
    local module, name = target[1], target[2]
    local object = type(module) == 'table' and module[name] or nil
    local metatable = type(object) == 'table' and getmetatable(object) or nil
    if type(metatable) == 'table' and type(metatable.replace_map) == 'function' then
      local record
      for _, item in ipairs(action_print_records) do
        if item.metatable == metatable then record = item end
      end
      if not record then
        local original = metatable.replace_map
        local wrapper
        wrapper = function(self, values, ...)
          if not (attached and ctx and ctx.enabled() and ACTION_OUTPUT_ENABLED) then
            return original(self, values, ...)
          end
          return original(self, projected_print_replacements(values), ...)
        end
        metatable.replace_map = wrapper
        action_print_records[#action_print_records + 1] =
          { metatable = metatable, original = original, wrapper = wrapper }
      end
    end
  end
end

local function release_action_print_hooks()
  for _, record in ipairs(action_print_records) do
    if record.metatable.replace_map == record.wrapper then
      record.metatable.replace_map = record.original
    end
  end
  action_print_records = {}
end

local function sync_all()
  ensure_action_print_hooks()
  sync(slots.window)
  sync(slots.previewer)
  sync(slots.pickers)
  sync(slots.refine)
  for _, name in ipairs(ACTION_SLOTS) do sync(slots[name]) end
  for _, name in ipairs(ACTION_REQUIRE_SLOTS) do sync(slots[name]) end
end

-- The pinned pickers.lua fires User TelescopeFindPre immediately before
-- create_layout(), after pickers.new already ran. It is the last public boundary
-- where the window/previewer modules are guaranteed loaded, so the very first
-- picker of a session gets the same display projection as later ones.
local function ensure_find_pre()
  if find_pre_group then return end
  find_pre_group = vim.api.nvim_create_augroup('NvimZhTelescopeFindPre', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = find_pre_group,
    pattern = 'TelescopeFindPre',
    desc = 'nvim-zh: project Telescope window titles before the first layout',
    callback = function()
      if attached and ctx and ctx.enabled() then
        sync(slots.window)
        sync(slots.previewer)
      end
    end,
  })
end


function M.attach(next_ctx)
  if not next_ctx.enabled() then
    M.detach()
    return
  end
  ctx = next_ctx
  attached = true
  if not release_notification then
    release_notification = ctx.register_source({
      title = 'telescope.nvim',
      domain = DOMAIN,
      context = 'notification',
    })
  end
  ensure_find_pre()
  ACTION_OUTPUT_ENABLED = true
  sync_all()
end

function M.detach()
  attached = false
  ACTION_OUTPUT_ENABLED = false
  release_action_print_hooks()
  if find_pre_group then
    pcall(vim.api.nvim_del_augroup_by_id, find_pre_group)
    find_pre_group = nil
  end
  if release_notification then
    local release = release_notification
    release_notification = nil
    release()
  end
  for _, slot in pairs(slots) do
    if slot.generation ~= nil then common.unwrap(slot.records, slot.key) end
  end
end

local function seam_info(slot)
  local current = loaded_module(slot)
  if current == nil or current == false then
    return { active = false, reason = 'not_loaded' }
  end
  if current ~= slot.generation then
    return { active = false, reason = 'stale_generation' }
  end
  if slot.unavailable then return { active = false, reason = slot.unavailable } end
  return {
    active = attached and common.active(slot.records, slot.key) or false,
    reason = common.reason(slot.records, slot.key),
  }
end

local function action_info(name)
  return seam_info(slots[name])
end

-- The prompt/output surfaces are owned by several public actions, so their
-- status is the union of the per-action seams rather than a single module
-- wrapper. Every action reports its own reason, which keeps a failed attach
-- visible without hiding the others.
local function prompt_info(actions)
  local reason
  for _, name in ipairs(INPUT_ACTIONS) do
    local info = actions[name]
    if info.active then return { active = true } end
    reason = reason or info.reason
  end
  return { active = false, reason = reason }
end

-- action_output is owned by the git_delete_branch action (scoped print) plus
-- the pickers replacement hook; report the union of those owned seams.
local function print_slot_active()
  if common.active(slots.git_delete_branch.records, slots.git_delete_branch.key) then return true end
  for _, name in ipairs(ACTION_REQUIRE_SLOTS) do
    local slot = slots[name]
    if common.active(slot.records, slot.key) then return true end
  end
  return false
end

local function action_output_info()
  if attached and ctx and ctx.enabled() and print_slot_active() then
    return { active = true }
  end
  return { active = false, reason = 'not_installed' }
end

function M.info(current_ctx)
  local window = seam_info(slots.window)
  local previewer = seam_info(slots.previewer)
  local lifecycle = seam_info(slots.pickers)
  local refine = seam_info(slots.refine)
  local which_key = seam_info(slots.which_key)
  local actions = {}
  for _, name in ipairs(ACTION_SLOTS) do actions[name] = action_info(name) end
  local prompts = prompt_info(actions)
  local function loaded(slot)
    local module = loaded_module(slot)
    return module ~= nil and module ~= false
  end
  local any_loaded = loaded(slots.window) or loaded(slots.previewer) or loaded(slots.pickers)
  local display_active = current_ctx.enabled() and attached
    and (window.active or previewer.active or refine.active or which_key.active) or false
  local degraded = window.reason == 'external_override'
    or previewer.reason == 'external_override'
    or lifecycle.reason == 'external_override'
    or refine.reason == 'external_override'
    or which_key.reason == 'external_override'
    or window.reason == 'unsupported_api'
    or previewer.reason == 'unsupported_api'
    or lifecycle.reason == 'unsupported_api'
  local reason
  if not attached or not current_ctx.enabled() then
    reason = 'disabled'
  elseif not any_loaded then
    reason = 'not_loaded'
  elseif display_active then
    reason = degraded and 'partially_active' or 'attached'
  elseif lifecycle.active then
    reason = 'lifecycle_only'
  elseif degraded then
    reason = 'external_override'
  else
    reason = window.reason ~= 'not_loaded' and window.reason
      or previewer.reason ~= 'not_loaded' and previewer.reason
      or lifecycle.reason
  end

  return {
    active = display_active,
    reason = reason,
    seam = 'pickers.window.get_initial_window_options; previewers.previewer.title; pickers.new(lifecycle); '
      .. 'actions.generate.refine display copies; actions.which_key plenary popup title; scoped vim.fn.input '
      .. 'prompts; scoped print for git_delete_branch and the three internal select callbacks; '
      .. 'vim.notify title source',
    domain = DOMAIN,
    window = window,
    previewer = previewer,
    lifecycle = lifecycle,
    refine = refine,
    which_key = which_key,
    actions = actions,
    prompts = prompts,
    action_output = action_output_info(),
    notification = {
      active = release_notification ~= nil,
      title = 'telescope.nvim',
      context = 'notification',
    },
    internal_titles = 'preserved',
    refine_change_title = 'covered_by_generate_refine_display_copy',
    error_values = 'untranslated_lua_error_no_display_route',
    entry_data = 'untranslated_entry_data',
    uncovered = 'Lua error() values have no display route (E5108) and the "Untitled" quickfix row is '
      .. 'entry data; both stay unchanged',
  }
end

function M.signature()
  local values = {}
  local names = { 'window', 'previewer', 'pickers', 'refine', 'which_key' }
  for _, name in ipairs(ACTION_SLOTS) do names[#names + 1] = name end
  for _, name in ipairs(ACTION_REQUIRE_SLOTS) do names[#names + 1] = name end
  for _, key in ipairs(names) do
    local slot = slots[key]
    local module = loaded_module(slot)
    values[#values + 1] = slot.module
    values[#values + 1] = tostring(module)
    if slot.action then
      local target = type(module) == 'table' and action_access(module, slot.action) or nil
      values[#values + 1] = target and tostring(target.get()) or 'missing'
    else
      values[#values + 1] = type(module) == 'table' and tostring(module[slot.method]) or 'missing'
    end
  end
  return table.concat(values, ':')
end

return M
