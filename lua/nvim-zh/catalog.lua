local M = {}

local SEP = '\031'
local BUILTIN_SOURCES = {
  ['nvim-ui'] = 'translations/po/zh_CN/nvim-ui.po',
}
local registrations = {}
local loaded = {}
local overrides = {}
local bundled_sources
local revisions = {}
local verified = setmetatable({}, { __mode = "k" })

local function invalidate(domain)
  loaded[domain] = nil
  revisions[domain] = (revisions[domain] or 0) + 1
end

function M.revision(domain) return revisions[domain] or 0 end

local function valid_domain(domain)
  return type(domain) == 'string' and domain:match('^[%w][%w_.%-]*$') ~= nil
end

local function valid_context(context)
  return type(context) == 'string' and not context:find(SEP, 1, true)
end

local function validate_override_value(value)
  if type(value) == 'string' then return value end
  if type(value) ~= 'table' or type(value.msgstr) ~= 'string' then return nil end
  for key in pairs(value) do
    if key ~= 'msgstr' then return nil end
  end
  return value.msgstr
end

local function validate_overrides(value)
  if value == nil then return {} end
  if type(value) ~= 'table' then error('nvim-zh: overrides must be a data table', 3) end
  for domain, contexts in pairs(value) do
    if not valid_domain(domain) or type(contexts) ~= 'table' then
      error('nvim-zh: overrides must be indexed by valid domain and explicit context', 3)
    end
    for context, entries in pairs(contexts) do
      if not valid_context(context) or type(entries) ~= 'table' then
        error('nvim-zh: override contexts must be string keys containing data entries', 3)
      end
      for msgid, translation in pairs(entries) do
        if type(msgid) ~= 'string' or msgid == '' or validate_override_value(translation) == nil then
          error('nvim-zh: override entries must contain only string msgid/msgstr data', 3)
        end
      end
    end
  end
  return vim.deepcopy(value)
end

function M.configure(config)
  local next_overrides = validate_overrides(config and config.overrides)
  if not vim.deep_equal(overrides, next_overrides) then
    local changed = {}
    for domain, entries in pairs(overrides) do
      if not vim.deep_equal(entries, next_overrides[domain]) then changed[domain] = true end
    end
    for domain in pairs(next_overrides) do
      if overrides[domain] == nil then changed[domain] = true end
    end
    overrides = next_overrides
    for domain in pairs(changed) do
      local state = loaded[domain]
      if state and state.catalog and (registrations[domain] or overrides[domain]) then
        M._apply_overrides(state.catalog)
        revisions[domain] = (revisions[domain] or 0) + 1
      else
        invalidate(domain)
      end
    end
  end
end

function M.register(domain, loader, metadata)
  if not valid_domain(domain) or type(loader) ~= 'function' then
    error('nvim-zh: register_catalog expects a valid domain and loader function', 2)
  end
  if registrations[domain] then error('nvim-zh: catalog already registered: ' .. domain, 2) end
  if metadata ~= nil and type(metadata) ~= 'table' then
    error('nvim-zh: catalog metadata must be a table', 2)
  end
  registrations[domain] = { loader = loader, metadata = vim.deepcopy(metadata or {}), loads = 0 }
  -- A lookup before registration may have cached either a missing catalog or an
  -- overrides-only catalog. Rebuild it so late registration takes effect.
  invalidate(domain)
  return true
end

function M.is_registered(domain)
  return registrations[domain] ~= nil
end

function M.is_builtin(domain)
  return BUILTIN_SOURCES[domain] ~= nil
end

function M.register_owned(domain, loader, metadata)
  M.register(domain, loader, metadata)
  local record = registrations[domain]
  record.owned = true
  return function()
    if registrations[domain] == record then
      registrations[domain] = nil
      invalidate(domain)
    end
  end, function()
    if registrations[domain] == record then invalidate(domain) end
  end
end

-- Internal registrations own these require caches; user loaders retain control
-- of their own dependencies and are never subject to broad cache invalidation.
function M._register_builtin(domain, metadata)
  local module = 'nvim-zh.catalogs.generated.' .. domain
  M.register(domain, function()
    assert(bundled_sources ~= false, '内置资源尚未通过校验')
    if bundled_sources and bundled_sources[domain] then return bundled_sources[domain] end
    return require(module)
  end, metadata)
  registrations[domain].module = module
end

function M.register_builtins()
  for domain, source in pairs(BUILTIN_SOURCES) do
    if not M.is_registered(domain) then
      M._register_builtin(domain, { locale = 'zh_CN', source = source })
    end
  end
end

function M.builtin_domains()
  local domains = vim.tbl_keys(BUILTIN_SOURCES)
  table.sort(domains)
  return domains
end

local function validate_entry(entry, domain)
  return type(entry) == 'table'
    and valid_context(entry.context or '')
    and type(entry.msgid) == 'string' and entry.msgid ~= ''
    and type(entry.msgstr) == 'string' and entry.msgstr ~= ''
    and (entry.domain == nil or entry.domain == domain)
end

-- Templates with no leading literal are considered after anchored templates.
function M._template_key(text)
  return text:sub(1, 1):lower()
end

local function add_template(buckets_by_ctx, context, msgid)
  local first = msgid:sub(1, 1)
  local key = (first == '%' or first == '{') and '' or M._template_key(msgid)
  local buckets = buckets_by_ctx[context]
  if not buckets then
    buckets = {}
    buckets_by_ctx[context] = buckets
  end
  local bucket = buckets[key]
  if not bucket then
    bucket = {}
    buckets[key] = bucket
  end
  bucket[#bucket + 1] = msgid
  return bucket
end

local function is_map_table(value)
  return type(value) == 'table' and (next(value) == nil or not vim.islist(value))
end

local function validate_source(source, domain)
  assert(type(source) == 'table' and (source.schema == 1 or source.schema == 2) and source.domain == domain
    and type(source.locale) == 'string', 'invalid schema, domain, locale, or entries')
  if source.schema == 1 then
    assert(vim.islist(source.entries), 'invalid schema, domain, locale, or entries')
    local seen = {}
    for _, entry in ipairs(source.entries) do
      assert(validate_entry(entry, domain), 'invalid or empty catalog entry')
      local context = entry.context or ''
      local by_ctx = seen[context]
      if not by_ctx then by_ctx = {}; seen[context] = by_ctx end
      if by_ctx[entry.msgid] then error('duplicate domain/context/msgid: ' .. context .. SEP .. entry.msgid) end
      by_ctx[entry.msgid] = true
    end
    return
  end
  assert(is_map_table(source.entries), 'invalid schema, domain, locale, or entries')
  for context, map in pairs(source.entries) do
    assert(valid_context(context) and is_map_table(map), 'invalid or empty catalog entry')
    for msgid, msgstr in pairs(map) do
      assert(type(msgid) == 'string' and msgid ~= '' and type(msgstr) == 'string' and msgstr ~= '',
        'invalid or empty catalog entry')
    end
  end
end

local function build(source, domain)
  assert(type(source) == 'table' and (source.schema == 1 or source.schema == 2) and source.domain == domain
    and type(source.locale) == 'string', 'invalid schema, domain, locale, or entries')
  local skip_validate = verified[source] == domain
  local is_clang = domain == 'clang' or domain == 'clangd' or domain == 'clang-tidy'
  local exact, template_buckets, translated = {}, {}, {}
  local unesc, unsorted
  local total = 0
  local function index_entry(context, msgid, msgstr)
    if is_clang and msgid:find('%%', 1, true)
      and not msgid:gsub('%%%%', ''):find('%', 1, true) and not msgid:find('{', 1, true) then
      local u_id = msgid:gsub('%%%%', '%%')
      local u_str = msgstr:gsub('%%%%', '%%')
      local ex = exact[context]
      if not ex or ex[u_id] == nil then
        unesc = unesc or {}
        local u_ctx = unesc[context]
        if not u_ctx then u_ctx = {}; unesc[context] = u_ctx end
        if u_ctx[u_id] == nil then u_ctx[u_id] = { msgstr = u_str, orig = msgid } end
      end
    end
    total = total + 1
    local tr = translated[context]
    if not tr then tr = {}; translated[context] = tr end
    tr[msgstr] = msgid
    if msgid:find('{', 1, true) or msgid:find('%', 1, true) then
      return add_template(template_buckets, context, msgid)
    end
  end
  if source.schema == 1 then
    assert(vim.islist(source.entries), 'invalid schema, domain, locale, or entries')
    for _, entry in ipairs(source.entries) do
      if not skip_validate then
        assert(validate_entry(entry, domain), 'invalid or empty catalog entry')
      end
      local context = entry.context or ''
      local msgid, msgstr = entry.msgid, entry.msgstr
      local ex = exact[context]
      if not ex then ex = {}; exact[context] = ex end
      if not skip_validate and ex[msgid] ~= nil then
        error('duplicate domain/context/msgid: ' .. context .. SEP .. msgid)
      end
      ex[msgid] = msgstr
      index_entry(context, msgid, msgstr)
    end
  else
    assert(is_map_table(source.entries), 'invalid schema, domain, locale, or entries')
    exact = source.entries
    unsorted = {}
    for context, map in pairs(source.entries) do
      if not skip_validate then
        assert(valid_context(context) and is_map_table(map), 'invalid or empty catalog entry')
      end
      for msgid, msgstr in pairs(map) do
        if not skip_validate then
          assert(type(msgid) == 'string' and msgid ~= '' and type(msgstr) == 'string' and msgstr ~= '',
            'invalid or empty catalog entry')
        end
        local bucket = index_entry(context, msgid, msgstr)
        if bucket then unsorted[bucket] = true end
      end
    end
  end
  if unesc then
    for context, u_ctx in pairs(unesc) do
      local ex = exact[context]
      if ex then
        for u_id in pairs(u_ctx) do
          if ex[u_id] ~= nil then u_ctx[u_id] = nil end
        end
        if next(u_ctx) == nil then unesc[context] = nil end
      end
    end
    if next(unesc) == nil then unesc = nil end
  end
  return {
    domain = domain,
    locale = source.locale,
    metadata = source.metadata or {},
    exact = exact,
    unesc = unesc,
    template_buckets = template_buckets,
    translated = translated,
    base_total = total,
    total = total,
    _unsorted = unsorted,
    _bucket_state = {},
    _merged_buckets = nil,
  }
end

local function apply_overrides(catalog)
  local domain_overrides = overrides[catalog.domain]
  catalog.ov_exact = nil
  catalog.ov_translated = nil
  catalog.ov_buckets = nil
  catalog._merged_buckets = nil
  catalog._bucket_state = {}
  catalog.total = catalog.base_total
  if not domain_overrides or next(domain_overrides) == nil then return end
  local ov_exact, ov_translated, ov_buckets = {}, {}, nil
  local added = 0
  for context, entries in pairs(domain_overrides) do
    local ex = catalog.exact[context]
    local ov_ctx = {}
    ov_exact[context] = ov_ctx
    local tr_ctx = {}
    ov_translated[context] = tr_ctx
    for msgid, value in pairs(entries) do
      local msgstr = validate_override_value(value)
      ov_ctx[msgid] = msgstr
      tr_ctx[msgstr] = msgid
      if not ex or ex[msgid] == nil then
        added = added + 1
        if msgid:find('{', 1, true) or msgid:find('%', 1, true) then
          ov_buckets = ov_buckets or {}
          add_template(ov_buckets, context, msgid)
        end
      end
    end
  end
  if ov_buckets then
    for _, buckets in pairs(ov_buckets) do
      for _, bucket in pairs(buckets) do table.sort(bucket) end
    end
  end
  catalog.ov_exact = ov_exact
  catalog.ov_translated = ov_translated
  catalog.ov_buckets = ov_buckets
  catalog.total = catalog.base_total + added
end

M._apply_overrides = apply_overrides

function M.build_source(source, domain)
  assert(valid_domain(domain), 'invalid domain')
  return build(source, domain)
end

function M.register_prebuilt(domain, built_catalog, metadata)
  if not valid_domain(domain) or type(built_catalog) ~= 'table' or built_catalog.domain ~= domain then
    error('nvim-zh: register_prebuilt expects a valid domain and built catalog', 2)
  end
  if registrations[domain] then error('nvim-zh: catalog already registered: ' .. domain, 2) end
  if metadata ~= nil and type(metadata) ~= 'table' then
    error('nvim-zh: catalog metadata must be a table', 2)
  end
  local record = { owned = true, prebuilt = built_catalog, metadata = vim.deepcopy(metadata or {}), loads = 1 }
  registrations[domain] = record
  apply_overrides(built_catalog)
  loaded[domain] = { catalog = built_catalog }
  revisions[domain] = (revisions[domain] or 0) + 1
  local function release()
    if registrations[domain] == record then
      registrations[domain] = nil
      record.prebuilt = nil
      invalidate(domain)
    end
  end
  local function update(next_catalog)
    if registrations[domain] ~= record then return end
    assert(type(next_catalog) == 'table' and next_catalog.domain == domain, 'invalid prebuilt catalog')
    record.prebuilt = next_catalog
    apply_overrides(next_catalog)
    loaded[domain] = { catalog = next_catalog }
    revisions[domain] = (revisions[domain] or 0) + 1
  end
  return release, update
end

function M.get(domain)
  if not valid_domain(domain) then return nil, 'invalid domain' end
  local registration = registrations[domain]
  if not registration then
    local packs = package.loaded['nvim-zh.packs']
    if packs then packs.prepare_domain(domain) end
    registration = registrations[domain]
  end
  if loaded[domain] then
    return loaded[domain].catalog, loaded[domain].error
  end
  if not registration and not overrides[domain] then
    loaded[domain] = { error = 'catalog not registered' }
    return nil, loaded[domain].error
  end
  if registration and registration.prebuilt then
    apply_overrides(registration.prebuilt)
    loaded[domain] = { catalog = registration.prebuilt }
    return registration.prebuilt
  end
  local source = { schema = 1, domain = domain, locale = 'zh_CN', entries = {} }
  if registration then
    registration.loads = registration.loads + 1
    local ok, result = pcall(registration.loader)
    if not ok then
      loaded[domain] = { error = tostring(result) }
      return nil, loaded[domain].error
    end
    source = result
  end
  local ok, catalog_or_error = pcall(build, source, domain)
  if not ok then
    loaded[domain] = { error = tostring(catalog_or_error) }
    return nil, loaded[domain].error
  end
  apply_overrides(catalog_or_error)
  loaded[domain] = { catalog = catalog_or_error }
  return catalog_or_error
end

function M.is_translation(domain, context, msgid)
  local catalog = M.get(domain)
  if not catalog then return nil end
  local ctx = context or ''
  local ov = catalog.ov_translated
  if ov then
    local m = ov[ctx]
    if m and m[msgid] then return catalog.domain .. ':' .. ctx .. ':' .. m[msgid] end
    if ctx ~= '' then
      m = ov['']
      if m and m[msgid] then return catalog.domain .. '::' .. m[msgid] end
    end
  end
  local m = catalog.translated[ctx]
  if m and m[msgid] then return catalog.domain .. ':' .. ctx .. ':' .. m[msgid] end
  if ctx ~= '' then
    m = catalog.translated['']
    if m and m[msgid] then return catalog.domain .. '::' .. m[msgid] end
  end
end

function M.reload()
  local count = 0
  for domain, registration in pairs(registrations) do
    if not registration.owned then invalidate(domain) end
    if registration.module then package.loaded[registration.module] = nil end
    count = count + 1
  end
  return count
end

function M.inventory()
  local domains = {}
  for domain, state in pairs(loaded) do
    if state.catalog then
      table.insert(domains, { domain = domain, entries = state.catalog.total })
    end
  end
  table.sort(domains, function(a, b) return a.domain < b.domain end)
  return domains
end

function M._key_separator() return SEP end

-- Validate every candidate before replacing any live builtin catalog.
function M.prepare_sources(sources)
  assert(type(sources) == 'table', 'invalid bundled catalogs')
  for domain, source in pairs(sources) do
    assert(valid_domain(domain), 'invalid bundled domain')
    validate_source(source, domain)
    verified[source] = domain
  end
  return sources
end

function M.use_sources(sources)
  local old = bundled_sources
  bundled_sources = sources
  for domain, registration in pairs(registrations) do
    if registration.module and old ~= sources then invalidate(domain) end
  end
  return old
end

function M.validate_overrides(value) return validate_overrides(value) end

return M
