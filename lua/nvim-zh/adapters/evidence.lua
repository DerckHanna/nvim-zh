local M = {}
local fs = require('nvim-zh.fs')
local uv = vim.uv
local installed, observations = {}, {}
local explicit, sources = {}, {}
local on_load, project_health
local version = vim.version()
local nvim_version = not version.prerelease and ('%d.%d.%d'):format(version.major, version.minor, version.patch)
local verified = setmetatable({}, { __mode = 'k' })

local function index(id, spec)
  for surface_name, surface in pairs(spec.surfaces) do
    for name, path in pairs(surface.modules or {}) do
      -- Runtime-owned modules (e.g. vim.health) are provided by Neovim itself,
      -- not by the adapter's registered source tree; they are verified through
      -- the pinned runtime digest instead of the loading searcher.
      if not vim.startswith(name, 'vim.') then
        sources[name] = { id = id, spec = spec, path = path,
          health = surface_name == 'health' and name:match('%.health$') ~= nil }
      end
    end
  end
end

local function set_root(id, root)
  local previous = installed[id]
  if previous and previous.root == root then return previous end
  local installation = { root = root, epoch = 0, sequence = 0 }
  installed[id] = installation
  observations[id] = nil
  return installation
end

local function pack_root(source, actual)
  -- Query only when Neovim resolves a module named by the manifest.
  -- info=false reads vim.pack state without spawning Git.
  local ok, packages = pcall(vim.pack.get, nil, { info = false })
  if not ok then return end
  local repository = source.spec.repository
  for _, package in ipairs(packages) do
    local src = package.spec.src
    if package.active and (src == repository or src == repository .. '.git') then
      local root = uv.fs_realpath(package.path)
      if root and root .. '/' .. source.path == actual then return root end
    end
  end
end

local function load_health(chunk, source, digest, current)
  if not source.health then return end
  for _, target in pairs(source.spec.targets) do
    if target.neovim == nvim_version and target.sources[source.path] == digest then
      local proxy = setmetatable({}, { __index = vim.health })
      for _, method in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
        proxy[method] = function(message, ...)
          local translate = project_health
          if translate and current() and type(message) == 'string' then
            message = translate(source.id, message)
          end
          return vim.health[method](message, ...)
        end
      end
      setfenv(chunk, setmetatable({ vim = setmetatable({ health = proxy }, { __index = vim }) }, { __index = _G }))
      return
    end
  end
end

-- Some display expressions live inside private callbacks or share a renderer
-- with protocol data. Project those expressions from the verified input bytes,
-- before anything can capture an unprojected alias. Keep the original chunk as
-- a fallback and give the projection a generation guard for delayed callbacks.
local function project(chunk, source, module, bytes, digest, actual, current)
  if not source.spec.source_projection then return chunk end
  for _, target in pairs(source.spec.targets) do
    if target.neovim == nvim_version and target.sources[source.path] == digest then
      local ok, projected = pcall(function()
        local adapter = require(source.spec.entry)
        return adapter.project_source(module, bytes, actual, current)
      end)
      if ok and type(projected) == 'function' then return projected end
      break
    end
  end
  return chunk
end

local function loader(module)
  local source = sources[module]
  if not source then return end
  local file = vim.api.nvim_get_runtime_file(source.path, false)[1]
  local actual = file and uv.fs_realpath(file)
  if not actual then return end
  local id = source.id
  local root = explicit[id] and explicit[id] or pack_root(source, actual)
  if not root or root .. '/' .. source.path ~= actual then return end
  local ok, bytes = pcall(fs.read, actual, 4 * 1024 * 1024)
  if not ok then return end
  local chunk = loadstring(bytes, '@' .. actual)
  if not chunk then return end
  local installation = set_root(id, root)
  local epoch = installation.epoch
  local digest = vim.fn.sha256(bytes)
  local observation
  local function current()
    return observation ~= nil and observations[id] and observations[id][module] == observation
      and installed[id] == installation and installation.epoch == epoch
      and rawequal(package.loaded[module], observation.object)
  end
  load_health(chunk, source, digest, current)
  local original = chunk
  chunk = project(chunk, source, module, bytes, digest, actual, current)
  return function(...)
    local object = chunk(...)
    observations[id] = observations[id] or {}
    observation = {
      object = object or package.loaded[module],
      sha256 = digest, installation = installation, epoch = epoch, projected = chunk ~= original,
    }
    observations[id][module] = observation
    installation.sequence = installation.sequence + 1
    if on_load then on_load(id) end
    return object
  end, actual
end

local function ensure_searcher()
  if package.loaders[2] == loader then return end
  for i, searcher in ipairs(package.loaders) do
    if searcher == loader then table.remove(package.loaders, i); break end
  end
  table.insert(package.loaders, 2, loader)
end

function M.setup(specs, loaded, health)
  for id, spec in pairs(specs) do index(id, spec) end
  on_load, project_health = loaded, health
  ensure_searcher()
end

function M.stop()
  on_load, project_health = nil, nil
  -- Keep observing explicitly registered sources loaded while auto is disabled.
  for module, source in pairs(sources) do
    if not explicit[source.id] then sources[module] = nil end
  end
end

function M.register(id, spec, root)
  assert(type(root) == 'string', 'adapter source directory must be a string')
  root = uv.fs_realpath(root)
  local stat = root and uv.fs_stat(root)
  assert(stat and stat.type == 'directory', 'adapter source directory does not exist')
  explicit[id] = root
  set_root(id, root)
  index(id, spec)
  ensure_searcher()
end

function M.verify(id, spec, surface)
  local found = observations[id] or {}
  local installation = installed[id]
  local plugin_modules = false
  local considered = surface.modules
  if surface.independent then
    considered = {}
    for name, path in pairs(surface.modules) do
      if package.loaded[name] then considered[name] = path end
    end
    if not next(considered) then return nil, 'not_loaded' end
  end
  for name in pairs(considered) do
    if not vim.startswith(name, 'vim.') then
      plugin_modules = true
      local value = found[name]
      if not value then return nil, 'unknown_version' end
      if value.installation ~= installation or value.epoch ~= installation.epoch
          or not rawequal(value.object, package.loaded[name]) then
        return nil, 'stale_generation'
      end
      if spec.source_projection and not value.projected then
        return nil, 'unsupported_revision'
      end
    end
  end
  -- A surface made only of runtime-owned modules still needs the adapter's
  -- loading evidence to exist before it can claim a fixed combination.
  if not plugin_modules and not installation then return nil, 'unknown_version' end
  local cache = not surface.independent and verified[surface]
  local sequence = installation and installation.sequence or 0
  if cache and cache.installation == installation and cache.sequence == sequence then
    return cache.result, cache.reason
  end
  local matches = {}
  for _, target in ipairs(vim.fn.sort(vim.tbl_keys(spec.targets))) do
    local candidate = spec.targets[target]
    local mismatch = candidate.neovim ~= nvim_version
    for name, path in pairs(considered) do
      local digest
      if vim.startswith(name, 'vim.') then
        -- Runtime-owned module: hash the raw bytes of the loaded runtime file
        -- (readfile would normalize line endings and change the digest). The
        -- pinned Neovim version gate above already restricts the combination.
        local ok, data = pcall(fs.read, vim.env.VIMRUNTIME .. '/' .. path, 4 * 1024 * 1024)
        digest = ok and vim.fn.sha256(data) or nil
      else
        digest = found[name].sha256
      end
      if digest ~= candidate.sources[path] then
        mismatch = true
        break
      end
    end
    if not mismatch then
      matches[#matches + 1] = { target = target, tested_commit = candidate.commit }
    end
  end
  local result = #matches > 0 and { kind = 'fixed_sources', matches = matches } or nil
  local reason = not result and 'unsupported_revision' or nil
  if not surface.independent then
    verified[surface] = { installation = installation, sequence = sequence, result = result, reason = reason }
  end
  return result, reason
end

function M.changed(path)
  if type(path) ~= 'string' then return end
  local root = uv.fs_realpath(path) or vim.fs.normalize(path)
  for id, installation in pairs(installed) do
    if installation.root == root then
      installation.epoch = installation.epoch + 1
      return id
    end
  end
end

function M.health_status(id, spec)
  local surface = spec.surfaces.health
  local result, reason = M.verify(id, spec, surface)
  return { active = result ~= nil and project_health ~= nil, reason = reason }
end

return M
