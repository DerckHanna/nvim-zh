local M = {}

local specs = {}
local evidence = require('nvim-zh.adapters.evidence')
local common = require('nvim-zh.adapters.common')
local uv = vim.uv
local adapters, names, failures = {}, {}, {}
local installed, external, managed, source_dirs = {}, {}, {}, {}

local config = { auto = false, lazy_load = true, disabled = {} }
local AUGROUP = 'NvimZhPluginLateLoad'
-- Some supported plugins finish loading after nvim-zh setup without emitting
-- User LazyLoad (e.g. which-key auto-setups on a 500ms timer). Their module
-- signature only changes once loading completes, so a bounded startup sweep
-- re-attaches adapters when that happens. It never forces a plugin to load and
-- stops as soon as the signature is stable; FocusGained/BufEnter and LazyLoad
-- remain the long-term boundaries.
local startup_timers, startup_group = {}, nil
local startup_signature
local STARTUP_DELAYS = { 60, 200, 500, 1000, 1600 }

local function enabled(name)
  if not config.auto then return false end
  for _, disabled in ipairs(config.disabled or {}) do
    if disabled == name then return false end
  end
  return true
end

-- A notification belongs to a plugin only when a frame of that plugin's own
-- pinned source is on the stack. `paths` may name more than one real dispatch
-- origin (a plugin can call vim.notify from its util module and, on some
-- branches, straight from a public module); each origin is checked against the
-- concrete file the loader would resolve, so an unrelated caller that merely
-- looks similar never matches.
local function match_notification(paths, opts)
  if type(paths) == 'string' then paths = { paths } end
  if type(paths) ~= 'table' then return false end
  local provenance = {}
  local function matches(info)
    local source = info and info.source
    if type(source) ~= 'string' or source:sub(1, 1) ~= '@' then return false end
    local file = source:sub(2)
    for _, path in ipairs(paths) do
      if source:sub(-#path - 1) == '/' .. path then
        provenance[path] = provenance[path] or vim.api.nvim_get_runtime_file(path, false)[1]
        if provenance[path] and uv.fs_realpath(file) == uv.fs_realpath(provenance[path]) then
          return true
        end
      end
    end
    return false
  end
  if type(opts.on_open) == 'function' and matches(debug.getinfo(opts.on_open, 'S')) then return true end
  for level = 3, 12 do
    local info = debug.getinfo(level, 'S')
    if not info then return false end
    if matches(info) then return true end
  end
  return false
end

local function context(id)
  local owner = specs[id]
  return {
    enabled = function() return specs[id] == owner and enabled(id) end,
    translate = common.translate,
    verify = function(surface)
      if specs[id] ~= owner then return nil, 'stale_generation' end
      local rule = owner.surfaces[surface]
      if not rule then return nil, 'unsupported_api' end
      if rule.kind ~= 'versioned' then return { kind = 'api_contract' } end
      return evidence.verify(id, owner, rule)
    end,
    register_source = function(spec)
      local rule = owner.surfaces.notifications
      if rule and rule.source then
        spec = vim.tbl_extend('force', spec, { matches = function(opts)
          return match_notification(rule.source, opts)
        end })
      end
      return require('nvim-zh.ui').register_source(spec)
    end,
  }
end

local function attach_one(id)
  local spec = specs[id]
  if not spec or (not spec.load and not external[id]) then return end
  local adapter = adapters[id]
  if not enabled(id) then
    if adapter then adapter.detach() end
    failures[id] = nil
    return
  end
  local ok, failure = pcall(function()
    if not adapter then
      adapter = spec.load()
      adapters[id] = adapter
    end
    adapter.attach(context(id))
  end)
  failures[id] = not ok and tostring(failure) or nil
  if not ok and adapter then pcall(adapter.detach) end
end

local function clear_lazy_load()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

local function sync_help()
  require('nvim-zh.help').sync_adapters(specs, enabled)
end

local function setup_lazy_load()
  clear_lazy_load()
  if not config.auto or not config.lazy_load then return end
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LazyLoad',
    desc = 'nvim-zh: adapt supported plugins after lazy.nvim loads them',
    callback = function(event)
      local matched = false
      for _, id in ipairs(names) do
        if vim.tbl_contains(specs[id].lazy_names, event.data) then
          attach_one(id)
          matched = true
        end
      end
      if matched then sync_help() end
    end,
  })
end

local function clear_startup_timers()
  if startup_group then
    vim.api.nvim_del_augroup_by_id(startup_group)
    startup_group = nil
  end
  for _, timer in ipairs(startup_timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  startup_timers = {}
  startup_signature = nil
end

local function attach_all()
  for _, id in ipairs(names) do attach_one(id) end
  sync_help()
end

local pending = {}
local function source_loaded(id)
  if pending[id] then return end
  pending[id] = true
  vim.schedule(function()
    pending[id] = nil
    if enabled(id) then attach_one(id); sync_help() end
  end)
end

local function translate_health(id, text)
  if enabled(id) and evidence.verify(id, specs[id], specs[id].surfaces.health) then
    return common.translate(specs[id].domain, 'health', text)
  end
  return text
end

-- Re-attach only when the loaded-module signature actually changed, so a stable
-- session does no repeated work and an external replacement is never reclaimed.
local function startup_sweep()
  if not config.auto then return end
  local signature = M.loaded_signature()
  if signature == startup_signature then return end
  startup_signature = signature
  attach_all()
end

local function schedule_startup_sweep()
  clear_startup_timers()
  if not config.auto then return end
  startup_signature = M.loaded_signature()
  -- VimEnter is the earliest point after plugins and their auto-setup timers
  -- have run; sweep there first so a first popup right after startup already
  -- sees the owned display seam instead of waiting for the first timer tick.
  -- The bounded timers below still cover plugins that finish later.
  if vim.v.vim_did_enter == 0 then
    startup_group = vim.api.nvim_create_augroup('NvimZhPluginStartup', { clear = true })
    vim.api.nvim_create_autocmd('VimEnter', {
      group = startup_group,
      once = true,
      desc = 'nvim-zh: adapt plugins loaded during startup',
      callback = function() vim.schedule(startup_sweep) end,
    })
  end
  for _, delay in ipairs(STARTUP_DELAYS) do
    local timer = vim.uv.new_timer()
    startup_timers[#startup_timers + 1] = timer
    timer:start(delay, 0, vim.schedule_wrap(function()
      if timer:is_closing() then return end
      timer:close()
      startup_sweep()
    end))
  end
end

function M.setup(next_config)
  config = vim.deepcopy(next_config or config)
  if config.auto then
    evidence.setup(specs, source_loaded, translate_health)
  else
    evidence.stop()
  end
  setup_lazy_load()
  attach_all()
  schedule_startup_sweep()
end

function M.teardown()
  config = { auto = false, lazy_load = false, disabled = {} }
  evidence.stop()
  clear_lazy_load()
  clear_startup_timers()
  for _, adapter in pairs(adapters) do adapter.detach() end
  sync_help()
end

function M.loaded_signature()
  local values = { vim.o.runtimepath }
  for _, id in ipairs(names) do
    local adapter = adapters[id]
    local spec = specs[id]
    values[#values + 1] = id
    if adapter and adapter.signature then
      values[#values + 1] = adapter.signature()
    else
      for _, name in ipairs(spec.modules) do
        values[#values + 1] = tostring(package.loaded[name])
      end
    end
  end
  return table.concat(values, ':')
end

function M.info()
  local result = {}
  for _, id in ipairs(names) do
    local spec, adapter = specs[id], adapters[id]
    local ctx = context(id)
    local info = adapter and adapter.info(ctx) or {}
    info.enabled = ctx.enabled()
    info.reason = failures[id] and 'attach_failed' or spec.status == 'inventory_only' and 'inventory_only'
      or not info.enabled and 'disabled' or info.reason or 'not_loaded'
    info.error = failures[id]
    info.seam = info.seam or 'none'
    info.active = info.active == true
    info.installed = vim.deepcopy(installed[id])
    info.targets = {}
    info.surfaces = {}
    for name, target in pairs(spec.targets) do info.targets[name] = target.commit end
    for name, rule in pairs(spec.surfaces) do
      local verification, reason = ctx.verify(name)
      local key = rule.status_key or name
      local status = (info.slots and info.slots[key]) or info[key]
      if type(status) ~= 'table' then status = {} end
      if name == 'health' and rule.kind == 'versioned' then status = evidence.health_status(id, spec) end
      if rule.kind == 'help' then
        local help = require('nvim-zh.help').adapter_status(id)
        status = { active = help == 'active', reason = help }
        verification = status.active and { kind = 'document_sha256' } or nil
      end
      local active = info.enabled and verification ~= nil and status.active == true
      info.surfaces[name] = {
        active = active,
        status = active and 'active' or failures[id] and 'attach_failed'
          or not info.enabled and 'disabled' or reason or status.reason or 'not_loaded',
        evidence = vim.deepcopy(verification),
        error = status.error,
      }
    end
    result[id] = info
  end
  return result
end

function M.register_adapter(definition)
  assert(type(definition) == 'table' and definition.api == 1, 'unsupported adapter API')
  local id, domain = definition.id, definition.domain
  assert(type(id) == 'string' and id:match('^[a-z0-9][a-z0-9_.%-]*$') and not specs[id],
    'invalid or duplicate adapter ID')
  assert(type(domain) == 'string' and domain:match('^[a-z0-9][a-z0-9_.%-]*$'),
    'external adapter needs a valid domain')
  assert(type(definition.surfaces) == 'table' and next(definition.surfaces), 'adapter needs surfaces')
  local spec = { domain = domain, status = 'implemented', surfaces = {},
    modules = {}, lazy_names = vim.deepcopy(definition.lazy_names or {}), targets = {} }
  assert(vim.islist(spec.lazy_names), 'adapter lazy_names must be an array')
  for name, handler in pairs(definition.surfaces) do
    assert(type(name) == 'string' and name:match('^[a-z0-9][a-z0-9_.%-]*$') and type(handler) == 'table'
      and type(handler.module) == 'string' and handler.module:match('^[%w_.%-]+$')
      and type(handler.probe) == 'function' and type(handler.mount) == 'function', 'invalid adapter surface')
    spec.surfaces[name] = { kind = 'api' }
    spec.modules[#spec.modules + 1] = handler.module
  end
  local catalog = require('nvim-zh.catalog')
  assert(not catalog.is_builtin(domain) and not catalog.is_registered(domain), 'adapter domain is already owned')
  local source = catalog.prepare_sources({ [domain] = definition.catalog })[domain]
  assert(source, 'external adapter needs a catalog')
  local release = catalog.register_owned(domain, function() return source end, { locale = source.locale })
  local entry = require('nvim-zh.adapters.scope').adapter(spec, vim.deepcopy(definition.surfaces))
  specs[id], adapters[id], external[id] = spec, entry, release
  names[#names + 1] = id
  table.sort(names)
  local function unregister()
    if external[id] ~= release then return end
    entry.detach()
    failures[id], specs[id], adapters[id], external[id] = nil, nil, nil, nil
    table.remove(names, vim.fn.index(names, id) + 1)
    release()
  end
  if config.auto then
    attach_one(id)
    local failure = failures[id]
    local states = entry.info().slots
    for name in pairs(spec.surfaces) do
      if states[name] and states[name].reason == 'attach_failed' then
        failure = failure or states[name].error
      end
    end
    if failure then
      unregister()
      error(failure, 0)
    end
  end
  return unregister
end

function M.check_managed(id, spec)
  assert(not specs[id] or managed[id], '适配包 ID 已在使用：' .. id)
  local others = vim.tbl_extend('force', {}, specs)
  others[id] = nil
  evidence.check_conflicts(others, spec)
end

function M.managed_entry(id) return managed[id] and adapters[id] end

function M.register_managed(id, spec, adapter, help_root)
  assert(not specs[id], '适配包 ID 已在使用：' .. id)
  M.check_managed(id, spec)
  local entry = adapter or { attach = function() end, detach = function() end, info = function() return {} end }
  spec.help_root = help_root
  spec.load = function() return entry end
  if source_dirs[id] then evidence.register(id, spec, source_dirs[id]) end
  specs[id], adapters[id], managed[id] = spec, entry, true
  names[#names + 1] = id
  table.sort(names)
  local function release()
    if specs[id] ~= spec then return end
    pcall(entry.detach)
    specs[id], adapters[id], failures[id], managed[id] = nil, nil, nil, nil
    table.remove(names, vim.fn.index(names, id) + 1)
    evidence.remove(id)
    sync_help()
  end
  if config.auto then evidence.setup(specs, source_loaded, translate_health) end
  attach_one(id)
  local ok, err = pcall(sync_help)
  local failure = failures[id] or (not ok and err)
  if failure then release(); error(failure, 0) end
  return release, sync_help
end

function M.register_source(id, directory)
  assert(type(id) == 'string' and id:match('^[a-z0-9][a-z0-9_.%-]*$'), 'invalid adapter ID')
  assert(type(directory) == 'string', 'adapter source directory must be a string')
  local root = uv.fs_realpath(directory)
  local stat = root and uv.fs_stat(root)
  assert(stat and stat.type == 'directory', 'adapter source directory does not exist')
  source_dirs[id] = root
  if not specs[id] then
    local pending_spec = require('nvim-zh.packs').spec_for_evidence(id)
    if pending_spec then evidence.register(id, pending_spec, root) end
    return
  end
  evidence.register(id, specs[id], root)
  if config.auto then attach_one(id); sync_help() end
end

function M.package_changed(data)
  if type(data) ~= 'table' or (data.kind ~= 'install' and data.kind ~= 'update' and data.kind ~= 'delete') then
    return false
  end
  local matched = evidence.changed(data.path)
  local changed = false
  for _, id in ipairs(names) do
    local spec = specs[id]
    local repo = data.spec and data.spec.src
    if matched == id or spec.repository and (repo == spec.repository or repo == spec.repository .. '.git') then
      installed[id] = { path = data.path, revision = data.rev or data.revision, kind = data.kind }
      if config.auto then attach_one(id) end
      changed = true
    end
  end
  if changed then sync_help() end
  return changed
end

return M
