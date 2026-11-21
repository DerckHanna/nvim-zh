local M = {}
local store = require('nvim-zh.pack_store')
local fs = require('nvim-zh.fs')
local official = 'https://raw.githubusercontent.com/DerckHanna/nvim-zh/packs/catalog.json'
local release_root = 'https://github.com/DerckHanna/nvim-zh/releases/download/'
local sources = { official = { url = official, allow_lua = true } }
local records, active, frozen, states, jobs, catalogs = {}, {}, {}, {}, {}, {}
local modules
local deferred = {}
local large_domains = { clang = true, clangd = true, ['clang-tidy'] = true }

local function changed()
  local lsp = package.loaded['nvim-zh.lsp']
  if lsp then lsp.refresh_display() end
  require('nvim-zh.list_display').refresh()
  require('nvim-zh.runtime').changed('packs')
end

local function trust(record)
  if record.source == 'local' then return record.allow_lua end
  local source = sources[record.source]
  return record.allow_lua and source and source.url == record.origin and source.allow_lua == true or false
end

local function release(id)
  local pack = active[id]
  if not pack then return end
  active[id] = nil
  if pack.release_adapter then pack.release_adapter() end
  if pack.release_catalog then pack.release_catalog() end
end

local function compatible_contract(previous, candidate)
  return vim.deep_equal(previous.manifest.adapter, candidate.manifest.adapter)
    and previous.manifest.domain == candidate.manifest.domain
    and previous.manifest.executable == candidate.manifest.executable
    and previous.entry == candidate.entry
end

local function mount(id, candidate, revision)
  for other_id, other in pairs(active) do
    if other_id ~= id then
      for tag in pairs(candidate.tags) do
        assert(not other.candidate.tags[tag], 'Help 标签已由 ' .. other_id .. ' 使用：' .. tag)
      end
    end
  end
  local existing = active[id]
  if existing then
    local old, old_root = existing.candidate, existing.spec and existing.spec.help_root
    existing.candidate = candidate
    if existing.spec then existing.spec.help_root = candidate.root .. '/help' end
    if existing.invalidate then existing.invalidate() end
    local ok, err = pcall(function() if existing.sync_help then existing.sync_help() end end)
    if not ok then
      existing.candidate = old
      if existing.spec then existing.spec.help_root = old_root end
      if existing.invalidate then existing.invalidate() end
      if existing.sync_help then pcall(existing.sync_help) end
      error(err, 0)
    end
    existing.revision = revision
    return
  end
  local pack = { candidate = candidate, revision = revision }
  local meta = candidate.manifest
  local previous = frozen[id]
  local ok, err = pcall(function()
    if candidate.catalog then
      pack.release_catalog, pack.invalidate = require('nvim-zh.catalog').register_owned(meta.domain,
        function() return pack.candidate.catalog end, { locale = 'zh_CN' })
    end
    if meta.adapter then
      local spec = vim.deepcopy(meta.adapter)
      local entry = previous and previous.entry
      if candidate.entry and not entry then
        local chunk = assert(loadstring(candidate.entry, '@' .. candidate.root .. '/adapter/entry.lua'))
        entry = chunk(spec)
        assert(type(entry) == 'table' and type(entry.attach) == 'function'
          and type(entry.detach) == 'function' and type(entry.info) == 'function', '包适配入口无效')
      end
      pack.release_adapter, pack.sync_help =
        require('nvim-zh.plugins').register_managed(id, spec, entry, candidate.root .. '/help')
      pack.spec = spec
      frozen[id] = { candidate = candidate, entry = entry }
    end
  end)
  if not ok then
    if pack.release_adapter then pack.release_adapter() end
    if pack.release_catalog then pack.release_catalog() end
    error(err, 0)
  end
  active[id] = pack
end

local function apply(id, record, prepared, failure)
  if record.error then error(record.error, 0) end
  if not record.selected then release(id); return end
  local state = { selected = record.selected.version, selected_sha256 = record.selected.sha256,
    source = record.selected.source, origin = record.selected.origin, enabled = record.enabled ~= false,
    previous = record.previous and record.previous.version,
    previous_sha256 = record.previous and record.previous.sha256 }
  states[id] = state
  local plugin_disabled = record.selected.kind ~= 'tool'
    and (not modules.plugins.auto or vim.tbl_contains(modules.plugins.disabled, id))
  if not state.enabled then
    release(id)
    state.reason = '已暂停'
    return
  end
  local current = active[id]
  if current and ((current.revision.allow_lua and not trust(current.revision))
    or not store.unchanged(current.candidate)) then
    release(id)
    current = nil
  end
  local reason
  local function attempt(revision)
    if failure and revision == record.selected then error(failure, 0) end
    if current and current.revision.sha256 == revision.sha256 then return true end
    local candidate = prepared and prepared[revision.sha256]
    if not candidate then candidate = store.load(id, vim.tbl_extend('force', revision, { allow_lua = trust(revision) })) end
    assert(not candidate.entry or trust(revision), '此来源的 Lua 入口需要明确授权')
    local retained = frozen[id]
    if retained and not compatible_contract(retained.candidate, candidate) then
      return false
    end
    if current and (not compatible_contract(current.candidate, candidate)
        or (current.candidate.catalog == nil) ~= (candidate.catalog == nil)) then
      return false
    end
    mount(id, candidate, revision)
    return true
  end
  local ok, switched = pcall(attempt, record.selected)
  if not ok or not switched then
    state.restart = ok
    reason = ok and '重启后应用选定版本' or tostring(switched)
    if not ok then state.error = reason end
    if not active[id] and record.previous then pcall(attempt, record.previous) end
  end
  local running = active[id]
  state.active = running and running.revision.version
  state.active_sha256 = running and running.revision.sha256
  state.reason = reason or (plugin_disabled and '配置已禁用' or nil)
end

local function can_defer(id, record)
  local selected = record.selected
  if not selected or record.enabled == false or active[id] or not large_domains[id]
    or selected.kind ~= 'tool' or selected.domain ~= id then return false end
  local stat = vim.uv.fs_stat(store.folder(selected) .. '/artifact.json')
  return stat and stat.type == 'file' and stat.size >= 256 * 1024
end

function M.ensure_tool(id, async, done)
  local target = deferred[id]
  if not target then return true end
  if done then target.callbacks[#target.callbacks + 1] = done end
  local function advance()
    if deferred[id] ~= target then return true end
    local ok, candidate = coroutine.resume(target.worker)
    if ok and coroutine.status(target.worker) ~= 'dead' then return false end
    deferred[id] = nil
    local selected = target.record.selected
    local prepared = ok and { [selected.sha256] = candidate } or nil
    apply(id, target.record, prepared, not ok and candidate or nil)
    for _, callback in ipairs(target.callbacks) do pcall(callback) end
    vim.schedule(function()
      if not modules or records[id] ~= target.record then return end
      local diagnostics = package.loaded['nvim-zh.diagnostics']
      if diagnostics then diagnostics.refresh_clients(id) end
      changed()
    end)
    return true
  end
  local pending = target.worker ~= nil
  if not pending then
    target.worker = coroutine.create(function()
      local selected = target.record.selected
      return store.load(id, vim.tbl_extend('force', selected, { allow_lua = trust(selected) }), coroutine.yield)
    end)
  end
  if not async then
    while not advance() do end
    return true
  end
  if not pending then
    local function step()
      if not advance() then vim.schedule(step) end
    end
    vim.schedule(step)
  end
  return false
end

function M.prepare_domain(domain)
  if deferred[domain] then M.ensure_tool(domain, false) end
end

function M.has_tool(id)
  if active[id] or deferred[id] then return true end
  for _, cache in pairs(catalogs) do
    for _, row in ipairs(cache.entries) do
      if row.id == id and row.tool and row.tool.protocol == 'cli' then return true end
    end
  end
  return false
end

function M.read()
  local snapshot = store.records()
  for id, record in pairs(snapshot) do
    assert(not record.error, '无法读取汉化包登记 ' .. id .. '：' .. tostring(record.error))
  end
  return snapshot
end

function M.snapshot() return records end

function M.sync(config, snapshot, prepared)
  if not (config or modules) then return end
  local ok, next_records = pcall(function() return snapshot or M.read() end)
  if not ok then return nil, next_records end
  modules = config or modules
  records, states = next_records, {}
  for id in pairs(deferred) do deferred[id] = nil end
  for id in pairs(active) do
    if not records[id] or not records[id].selected or records[id].enabled == false then release(id) end
  end
  for _, id in ipairs(vim.fn.sort(vim.tbl_keys(records))) do
    local record = records[id]
    local success, why
    if can_defer(id, record) and not (prepared and prepared[record.selected.sha256]) then
      deferred[id] = { record = record, callbacks = {} }
      states[id] = { selected = record.selected.version, selected_sha256 = record.selected.sha256,
        enabled = true, source = record.selected.source, origin = record.selected.origin,
        previous = record.previous and record.previous.version, reason = '等待相关工具', pending = true }
      success = true
    else
      success, why = pcall(apply, id, record, prepared)
    end
    if not success then
      states[id] = { reason = tostring(why), active = active[id] and active[id].revision.version }
    end
  end
  return true
end

function M.spec_for_evidence(id)
  local ok, result = pcall(function()
    local record = store.record(id)
    if record.selected and record.enabled ~= false then
      return store.load(id, record.selected).manifest.adapter
    end
  end)
  return ok and result or nil
end

function M.stop()
  modules = nil
  for id in pairs(active) do release(id) end
  for _, job in pairs(jobs) do
    if job.process then pcall(job.process.kill, job.process, 15) end
  end
  jobs, states, deferred = {}, {}, {}
end

local function parse_catalog(bytes, source)
  local doc = vim.json.decode(bytes)
  assert(doc.schema == 1 and vim.islist(doc.packages) and #doc.packages <= 4096, '无效的发布索引')
  local keys, entries = {}, {}
  for _, row in ipairs(doc.packages) do
    assert(type(row) == 'table' and store.id(row.id) and store.version(row.version) and store.https(row.url)
      and store.digest(row.sha256) and type(row.size) == 'number' and row.size >= 1
      and row.size <= store.limit and row.size % 1 == 0, '无效的发布索引记录')
    assert(row.name == nil or (type(row.name) == 'string' and #row.name <= 160), '无效的包名称')
    assert(row.description == nil or (type(row.description) == 'string' and #row.description <= 1000), '无效的包描述')
    assert(row.repository == nil or store.https(row.repository), '无效的目标仓库')
    assert(row.executable == nil or store.id(row.executable), '无效的目标工具')
    store.validate_tool(row.tool, row.executable)
    assert(source ~= 'official' or vim.startswith(row.url, release_root), '官方附件地址超出发布仓库')
    local key = row.id .. '@' .. row.version .. '/' .. tostring(row.locale)
    assert(not keys[key], '发布索引版本重复：' .. key)
    keys[key] = true
    if row.locale == 'zh_CN' and row.sdk == 1 then
      entries[#entries + 1] = row
    end
  end
  return entries
end

function M.configure(extra)
  local next_sources = { official = { url = official, allow_lua = true } }
  for id, source in pairs(extra or {}) do next_sources[id] = vim.deepcopy(source) end
  if vim.deep_equal(sources, next_sources) and next(catalogs) then return end
  sources, catalogs = next_sources, {}
  for id, source in pairs(sources) do
    local ok, cache = pcall(fs.json, store.root() .. '/catalogs/' .. id .. '.json', 4 * 1024 * 1024)
    if ok and cache.origin == source.url then
      local parsed, entries = pcall(parse_catalog, cache.body, id)
      if parsed then catalogs[id] = { entries = entries, checked_at = cache.checked_at } end
    end
  end
end

local function newer(a, b)
  return vim.version.gt(vim.version.parse(a), vim.version.parse(b))
end

local function target_state(row, installed, bufnr)
  if row.executable then
    local target = vim.fn.executable(row.executable) == 1
    if not row.tool then return target end
    if row.tool.protocol == 'cli' then
      local compiler = package.loaded['nvim-zh.compiler']
      if compiler then
        for executable, hashes in pairs(row.tool.binaries or {}) do
          local identity = compiler.identity(executable)
          if identity and row.tool.versions[identity.version] and vim.tbl_contains(hashes, identity.sha256) then
            return true, true
          end
        end
      end
      return target
    end
    local seen = false
    local clients = vim.lsp.get_clients({ bufnr = bufnr or 0, name = row.tool.server })
    if #clients == 0 then clients = vim.lsp.get_clients({ name = row.tool.server }) end
    for _, client in ipairs(clients) do
      local info = client.server_info
      if info and info.name == row.tool.server and row.tool.versions[info.version] then return true, true end
      seen = seen or client.initialized
    end
    if seen then return true, false end
    return target
  end
  if row.repository and installed[row.repository] then
    local rev = installed[row.repository].rev
    return true, type(rev) == 'string' and vim.islist(row.targets) and vim.tbl_contains(row.targets, rev) or nil
  end
  for _, name in ipairs(vim.islist(row.modules) and row.modules or {}) do
    if type(name) == 'string' and package.loaded[name] then return true end
  end
  return false
end

local function installed_targets()
  local installed = {}
  local ok, packages = pcall(vim.pack.get, nil, { info = false })
  if ok then
    for _, item in ipairs(packages) do
      if item.spec and type(item.spec.src) == 'string' then
        installed[item.spec.src:gsub('%.git$', '')] = item
      end
    end
  end
  return installed
end

local function candidates(id, source, installed, bufnr)
  local options = {}
  for name, cache in pairs(catalogs) do
    if not source or name == source then
      for _, row in ipairs(cache.entries) do
        if row.id == id then
          local _, compatible = target_state(row, installed, bufnr)
          local candidate = vim.tbl_extend('force', {}, row, { source = name })
          candidate.recommended = compatible == true
          candidate.compatibility = compatible == true and 'verified'
            or compatible == false and 'unsupported_version'
            or row.executable and not row.tool and 'legacy_pack' or 'unverified_target'
          options[#options + 1] = candidate
        end
      end
    end
  end
  table.sort(options, function(a, b)
    return a.version ~= b.version and newer(a.version, b.version) or a.version == b.version and a.source < b.source
  end)
  return options
end

local function recommended(options)
  for _, option in ipairs(options) do
    if option.recommended then return option end
  end
end

local function sync_state(prepared)
  if modules then
    local synced, failure = M.sync(nil, nil, prepared)
    assert(synced, failure)
  end
  changed()
end

local function finish(job, ok, message, done)
  if jobs[job.key] ~= job then return end
  job.phase, job.message, job.process = ok and '完成' or (job.cancelled and '已取消' or '失败'),
    message and tostring(message), nil
  job.finished = true
  changed()
  if done then done(ok, job.message) end
end

local function new_job(key, phase, done)
  if jobs[key] and not jobs[key].finished then
    if done then done(false, '该操作正在进行') end
    return
  end
  local job = { key = key, phase = phase }
  jobs[key] = job
  return job
end

local function fetch(job, url, limit, callback)
  assert(store.https(url), '需要 HTTPS 下载地址')
  assert(vim.fn.executable('curl') == 1, '网络操作需要 curl，可离线导入附件')
  local path = fs.unique(store.root() .. '/downloads/part')
  fs.mkdir(vim.fs.dirname(path))
  job.process = vim.system({ 'curl', '--disable', '--fail', '--silent', '--show-error',
    '--location', '--proto', '=https', '--proto-redir', '=https', '--max-time', '45',
    '--max-filesize', tostring(limit), '--output', path, '--url', url }, { text = true }, function(result)
    vim.schedule(function()
      local current = jobs[job.key] == job
      local ok, body
      if current and not job.cancelled and result.code == 0 then ok, body = pcall(fs.read, path, limit) end
      vim.uv.fs_unlink(path)
      if not current then return end
      job.process = nil
      if job.cancelled then callback(false, '操作已取消')
      elseif result.code ~= 0 then callback(false, vim.trim(result.stderr or '') ~= '' and result.stderr or '下载失败')
      else callback(ok, body) end
    end)
  end)
  changed()
end

function M.refresh_catalog(done)
  M.configure_cache()
  local job = new_job('@catalog', '正在获取目录', done)
  if not job then return end
  local names, errors = vim.fn.sort(vim.tbl_keys(sources)), {}
  local function next_source()
    local id = table.remove(names, 1)
    if not id or job.cancelled then
      finish(job, not job.cancelled and #errors == 0, job.cancelled and '操作已取消'
        or (#errors > 0 and table.concat(errors, '；') or '目录已刷新'), done)
      return
    end
    local source = sources[id]
    if not source then
      errors[#errors + 1] = id .. '：发布源已变更'
      next_source()
      return
    end
    local ok, why = pcall(fetch, job, source.url, 1024 * 1024, function(downloaded, body)
      local parsed, failure = pcall(function()
        assert(downloaded, body)
        local entries = parse_catalog(body, id)
        assert(sources[id] and sources[id].url == source.url, '发布源已变更')
        local checked = os.time()
        fs.write(store.root() .. '/catalogs/' .. id .. '.json',
          vim.json.encode({ origin = source.url, checked_at = checked, body = body }))
        catalogs[id] = { checked_at = checked, entries = entries }
      end)
      if not parsed then errors[#errors + 1] = id .. '：' .. tostring(failure) end
      next_source()
    end)
    if not ok then errors[#errors + 1] = id .. '：' .. tostring(why); next_source() end
  end
  next_source()
end

function M.configure_cache()
  if not next(catalogs) and not modules then M.configure() end
end

local function select_package(id, record, selected, candidate)
  local before = active[id]
  if candidate.catalog then
    local registry = require('nvim-zh.catalog')
    assert(not registry.is_builtin(candidate.manifest.domain), '包使用了主包词库域')
    local owns = before and before.candidate.catalog and before.candidate.manifest.domain == candidate.manifest.domain
    assert(owns or not registry.is_registered(candidate.manifest.domain), '词库域已在使用')
    for other_id, other in pairs(records) do
      assert(other_id == id or not other.selected or other.selected.domain ~= candidate.manifest.domain,
        '词库域已由 ' .. other_id .. ' 登记')
    end
  end
  if candidate.manifest.adapter then
    require('nvim-zh.plugins').check_managed(id, candidate.manifest.adapter)
  end
  if record.selected and record.selected.sha256 == selected.sha256 then
    -- The registration is already current. A snapshot repaired by this import
    -- may still be inactive after an earlier verification failure.
    local state = states[id]
    if modules and record.enabled ~= false and (not state or state.active_sha256 ~= selected.sha256) then
      sync_state({ [selected.sha256] = candidate })
      local failure = states[id] and states[id].error
      if failure then error(failure, 0) end
    end
    return
  end
  selected.domain = candidate.manifest.domain
  selected.kind = candidate.manifest.executable and 'tool' or 'plugin'
  local next_record = { selected = selected, previous = record.selected, enabled = record.enabled ~= false }
  store.commit(id, record.generation, next_record)
  local synced, sync_error = pcall(sync_state, { [selected.sha256] = candidate })
  local failure = not synced and sync_error or states[id] and states[id].error
  if failure then
    -- A concurrent writer may already have selected another revision.
    local restored, why = pcall(store.commit, id, next_record.generation, record)
    pcall(sync_state)
    error(restored and failure or (failure .. '；恢复包登记失败：' .. tostring(why)), 0)
  end
end

function M.install(row, done)
  local id = row.id
  local job = new_job(id, '正在下载', done)
  if not job then return end
  local ok, err = pcall(function()
    local record = store.record(id)
    local source = assert(sources[row.source], '发布源不可用')
    assert(not record.selected or (record.selected.source == row.source and record.selected.origin == source.url),
      '已安装的包来自其他来源，请先卸载')
    fetch(job, row.url, row.size, function(downloaded, bytes)
      local applied, failure = pcall(function()
        assert(downloaded, bytes)
        assert(sources[row.source] and sources[row.source].url == source.url
          and sources[row.source].allow_lua == source.allow_lua, '发布源已变更')
        job.phase = '正在校验'
        changed()
        assert(jobs[id] == job and not job.cancelled, '操作已取消')
        local candidate, sum = store.stage(bytes, row, source.allow_lua == true)
        job.phase = '正在应用'
        changed()
        assert(jobs[id] == job and not job.cancelled, '操作已取消')
        assert(sources[row.source] and sources[row.source].url == source.url
          and sources[row.source].allow_lua == source.allow_lua, '发布源已变更')
        select_package(id, record, { version = row.version, sha256 = sum, source = row.source,
          origin = source.url, allow_lua = source.allow_lua == true }, candidate)
      end)
      local state = states[id]
      finish(job, applied, applied and (state and state.reason or '包已安装') or failure, done)
    end)
  end)
  if not ok then finish(job, false, err, done) end
end

function M.import(path, allow_lua, inspected)
  local bytes = fs.read(vim.fn.fnamemodify(path, ':p'), store.limit)
  assert(not inspected or vim.fn.sha256(bytes) == inspected, '待导入文件已变更')
  local candidate, sum = store.stage(bytes, nil, allow_lua == true)
  local meta = candidate.manifest
  local record = store.record(meta.id)
  assert(not record.selected or record.selected.source == 'local', '同名远程包已安装，请先卸载')
  select_package(meta.id, record, { version = meta.version, sha256 = sum, source = 'local',
    allow_lua = allow_lua == true }, candidate)
  return meta.id
end

function M.inspect(path)
  local bytes = fs.read(vim.fn.fnamemodify(path, ':p'), store.limit)
  local doc = vim.json.decode(bytes)
  local meta = doc.manifest
  assert(type(meta) == 'table' and store.id(meta.id) and store.version(meta.version)
    and type(doc.files) == 'table', '无效的汉化包')
  return { id = meta.id, version = meta.version, lua = doc.files['adapter/entry.lua'] ~= nil, sha256 = vim.fn.sha256(bytes) }
end

function M.change(id, operation, expected)
  local record = store.record(id)
  assert(not expected or record.generation == expected, '包登记已变更，请重新选择')
  assert(record.selected, '包尚未安装')
  if operation == 'remove' then
    store.commit(id, record.generation, {})
    M.cancel(id)
    jobs[id] = nil
  elseif operation == 'rollback' then
    local previous = assert(record.previous, '没有可用的历史版本')
    local candidate = store.load(id, vim.tbl_extend('force', previous, { allow_lua = trust(previous) }))
    select_package(id, record, previous, candidate)
  else
    assert(operation == 'enable' or operation == 'disable', '未知包操作')
    if (record.enabled ~= false) == (operation == 'enable') then return end
    record.enabled = operation == 'enable'
    store.commit(id, record.generation, record)
  end
  if jobs[id] and jobs[id].finished then jobs[id] = nil end
  sync_state()
end

local function job_info(key)
  local job = jobs[key]
  return job and { phase = job.phase, message = job.message, finished = job.finished }
end

function M.cancel(id)
  local job = jobs[id]
  if not job or job.finished then return false end
  job.cancelled = true
  if job.process then pcall(job.process.kill, job.process, 15) end
  return true
end

function M.rows(bufnr)
  M.configure_cache()
  local rows, used, installed = {}, {}, installed_targets()
  local disk = modules and records or store.records()
  for id, record in pairs(disk) do
    if record.selected then
      local selected = record.selected
      local options = candidates(id, selected.source, installed, bufnr)
      local offer = recommended(options)
      local update = offer and (newer(offer.version, selected.version)
        or (offer.version == selected.version and offer.sha256 ~= selected.sha256)) and offer or nil
      local meta = active[id] and active[id].candidate.manifest
      local spec = meta and meta.adapter or {}
      local target, verified = target_state({ repository = spec.repository, modules = spec.modules,
        executable = meta and meta.executable, tool = meta and meta.tool }, installed, bufnr)
      local displays, observed
      if meta and meta.executable == 'clangd' then
        local lsp = package.loaded['nvim-zh.lsp']
        local status = lsp and lsp.info(bufnr)
        displays = status and status.clangd_clients
        local diagnostics = package.loaded['nvim-zh.diagnostics']
        local display = diagnostics and diagnostics.info()
        observed = verified == true and display and display.enabled
          and (display.virtual_text.active or display.virtual_lines.active or display.float.active)
      elseif meta and meta.executable then
        local compiler = package.loaded['nvim-zh.compiler']
        local status = compiler and compiler.info()
        local last = status and status.last
        observed = status and status.enabled and last and last.tool == id and last.results and (last.results.translated or 0) > 0
      end
      rows[#rows + 1] = { id = id, source = selected.source, name = id, installed = true,
        enabled = record.enabled ~= false, selected = selected.version, previous = record.previous and record.previous.version,
        update = update, options = options, state = states[id], job = job_info(id), generation = record.generation,
        target = target, verified = verified == true, display_active = observed == true, clients = displays,
        kind = selected.kind or (meta and meta.executable and 'tool') }
      used[id] = true
    elseif record.error then
      rows[#rows + 1] = { id = id, source = 'local', name = id, state = { reason = record.error } }
      used[id] = true
    end
  end
  local added = {}
  for source, cache in pairs(catalogs) do
    for _, row in ipairs(cache.entries) do
      local key = source .. ':' .. row.id
      if not used[row.id] and not added[key] then
        local options = candidates(row.id, source, installed, bufnr)
        local offer = recommended(options)
        local target, verified = target_state(offer or options[1] or row, installed, bufnr)
        rows[#rows + 1] = { id = row.id, source = source, name = row.name or row.id, description = row.description,
          target = target, verified = verified == true, update = offer, options = options, job = job_info(row.id) }
        added[key] = true
      end
    end
  end
  for id, job in pairs(jobs) do
    if id ~= '@catalog' and not used[id] and not vim.iter(rows):any(function(row) return row.id == id end) then
      rows[#rows + 1] = { id = id, source = 'local', name = id, job = job_info(id) }
    end
  end
  local checked
  for _, cache in pairs(catalogs) do checked = math.max(checked or 0, cache.checked_at or 0) end
  return vim.deepcopy(rows), checked, job_info('@catalog')
end

function M.info()
  local result = vim.deepcopy(states)
  for id in pairs(jobs) do
    if id ~= '@catalog' then
      result[id] = result[id] or {}
      result[id].job = job_info(id)
    end
  end
  return result
end

local requested_capabilities = {
  ['textDocument/codeAction'] = true,
  ['textDocument/completion'] = true,
  ['textDocument/diagnostic'] = true,
  ['textDocument/hover'] = true,
  ['textDocument/signatureHelp'] = true,
}

-- Tool identity comes from two verified sources: an LSP client's declared
-- serverInfo, or a command-line tool's own --version output. A target without
-- identity never authorizes a reviewed catalog.
function M.tool_reason(id, target, method)
  local pack = active[id]
  if not pack then
    if deferred[id] then return 'preparing_pack' end
    return states[id] and states[id].enabled == false and 'paused' or 'pack_missing'
  end
  local tool = pack.candidate.manifest.tool
  if not tool then return 'legacy_pack' end
  if type(target) ~= 'table' then return tool.protocol == 'cli' and 'tool_missing' or 'client_missing' end
  if tool.protocol == 'cli' then
    if target.server_info then
      local info = target.server_info
      if info.name ~= 'clangd' or not tool.forwarded or not tool.forwarded[info.version] then
        return 'unsupported_version'
      end
      return vim.tbl_contains(tool.forwarded[info.version], method) and 'verified' or 'unverified_interface'
    end
    if not target.version or not target.executable or not tool.versions[target.version] then
      return 'unsupported_version'
    end
    local hashes = tool.binaries and tool.binaries[target.executable]
    if not hashes or not target.sha256 or not vim.tbl_contains(hashes, target.sha256) then
      return 'unverified_binary'
    end
    if method and not vim.tbl_contains(tool.versions[target.version], method) then return 'unverified_interface' end
    return 'verified'
  end
  local info = target.server_info
  if not info or info.name ~= tool.server or not tool.versions[info.version] then return 'unsupported_version' end
  if method and not vim.tbl_contains(tool.versions[info.version], method) then return 'unverified_interface' end
  if requested_capabilities[method] and (type(target.supports_method) ~= 'function' or not target:supports_method(method)) then
    return 'unsupported_interface'
  end
  return 'verified'
end

function M.tool_allows(id, target, method)
  if not M.ensure_tool(id, true) then return false end
  local reason = M.tool_reason(id, target, method)
  return reason == 'verified' or reason == 'legacy_pack' or reason == 'pack_missing' or reason == 'paused'
end

return M
