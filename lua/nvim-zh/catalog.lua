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
    for domain, entries in pairs(overrides) do
      if not vim.deep_equal(entries, next_overrides[domain]) then invalidate(domain) end
    end
    for domain in pairs(next_overrides) do
      if overrides[domain] == nil then invalidate(domain) end
    end
    overrides = next_overrides
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

local function add_template(catalog, entry)
  local first = entry.msgid:sub(1, 1)
  local key = (first == '%' or first == '{') and '' or M._template_key(entry.msgid)
  local buckets = catalog.template_buckets[entry.context]
  if not buckets then
    buckets = {}
    catalog.template_buckets[entry.context] = buckets
  end
  local bucket = buckets[key]
  if not bucket then
    bucket = {}
    buckets[key] = bucket
  end
  bucket[#bucket + 1] = entry
end

local function validate_source(source, domain)
  assert(type(source) == 'table' and source.schema == 1 and source.domain == domain
    and type(source.locale) == 'string' and vim.islist(source.entries), 'invalid schema, domain, locale, or entries')
  local seen = {}
  for _, entry in ipairs(source.entries) do
    assert(validate_entry(entry, domain), 'invalid or empty catalog entry')
    local key = (entry.context or '') .. SEP .. entry.msgid
    if seen[key] then error('duplicate domain/context/msgid: ' .. key) end
    seen[key] = true
  end
end

local function build(source, domain)
  if verified[source] ~= domain then validate_source(source, domain) end
  local catalog = {
    domain = domain,
    locale = source.locale,
    metadata = source.metadata or {},
    exact = {},
    template_buckets = {},
    translated = {},
    total = 0,
  }
  for _, entry in ipairs(source.entries) do
    local context = entry.context or ''
    local key = context .. SEP .. entry.msgid
    local copy = { context = context, msgid = entry.msgid, msgstr = entry.msgstr,
      id = domain .. ':' .. context .. ':' .. entry.msgid }
    catalog.exact[key] = copy
    if (domain == 'clang' or domain == 'clangd' or domain == 'clang-tidy') and entry.msgid:find('%%', 1, true)
      and not entry.msgid:gsub('%%%%', ''):find('%', 1, true) and not entry.msgid:find('{', 1, true) then
      local unesc = { id = copy.id, context = copy.context }
      unesc.msgid = entry.msgid:gsub('%%%%', '%%')
      unesc.msgstr = entry.msgstr:gsub('%%%%', '%%')
      local unesc_key = context .. SEP .. unesc.msgid
      catalog.exact[unesc_key] = catalog.exact[unesc_key] or unesc
    end
    catalog.total = catalog.total + 1
    catalog.translated[context .. SEP .. entry.msgstr] = copy.id
    if entry.msgid:find('{', 1, true) or entry.msgid:find('%', 1, true) then
      add_template(catalog, copy)
    end
  end
  return catalog
end

local function apply_overrides(catalog)
  for context, entries in pairs(overrides[catalog.domain] or {}) do
    for msgid, value in pairs(entries) do
      local key = context .. SEP .. msgid
      local msgstr = validate_override_value(value)
      local entry = catalog.exact[key]
      if entry then
        entry.msgstr = msgstr
      else
        entry = {
          context = context,
          msgid = msgid,
          msgstr = msgstr,
          id = catalog.domain .. ':' .. context .. ':' .. msgid,
          override = true,
        }
        catalog.exact[key] = entry
        catalog.total = catalog.total + 1
        if msgid:find('{', 1, true) or msgid:find('%', 1, true) then add_template(catalog, entry) end
      end
      catalog.translated[context .. SEP .. msgstr] = entry.id
    end
  end
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
  return catalog.translated[(context or '') .. SEP .. msgid]
    or catalog.translated['' .. SEP .. msgid]
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
