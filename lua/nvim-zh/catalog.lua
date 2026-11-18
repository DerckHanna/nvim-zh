local M = {}

local SEP = '\031'
local BUILTIN_SOURCES = {
  ['nvim-ui'] = 'translations/po/zh_CN/nvim-ui.po',
  ['which-key'] = 'translations/po/zh_CN/which-key.po',
  telescope = 'translations/po/zh_CN/telescope.po',
  ['nvim-tree'] = 'translations/po/zh_CN/nvim-tree.po',
  ['nvim-dap'] = 'translations/po/zh_CN/nvim-dap.po',
  ['nvim-dap-ui'] = 'translations/po/zh_CN/nvim-dap-ui.po',
  clangd = 'translations/po/zh_CN/clangd.po',
}
local registrations = {}
local loaded = {}
local overrides = {}
local bundled_sources

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
    overrides = next_overrides
    loaded = {}
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
  loaded[domain] = nil
  return true
end

function M.is_registered(domain)
  return registrations[domain] ~= nil
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

local function build(source, domain)
  if type(source) ~= 'table' or source.schema ~= 1 or source.domain ~= domain
    or type(source.locale) ~= 'string' or type(source.entries) ~= 'table' then
    error('invalid schema, domain, locale, or entries')
  end
  local catalog = {
    domain = domain,
    locale = source.locale,
    metadata = source.metadata or {},
    exact = {},
    templates = {},
    translated = {},
    total = 0,
  }
  for _, entry in ipairs(source.entries) do
    if not validate_entry(entry, domain) then error('invalid or empty catalog entry') end
    local context = entry.context or ''
    local key = context .. SEP .. entry.msgid
    if catalog.exact[key] then error('duplicate domain/context/msgid: ' .. key) end
    local copy = vim.deepcopy(entry)
    copy.context = context
    copy.id = domain .. ':' .. context .. ':' .. entry.msgid
    catalog.exact[key] = copy
    catalog.total = catalog.total + 1
    catalog.translated[context .. SEP .. entry.msgstr] = copy.id
    if entry.msgid:find('{', 1, true) or entry.msgid:find('%%') then
      table.insert(catalog.templates, copy)
    end
  end
  table.sort(catalog.templates, function(a, b)
    if #a.msgid ~= #b.msgid then return #a.msgid > #b.msgid end
    return a.id < b.id
  end)
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
        if msgid:find('{', 1, true) or msgid:find('%%') then table.insert(catalog.templates, entry) end
      end
      catalog.translated[context .. SEP .. msgstr] = entry.id
    end
  end
  table.sort(catalog.templates, function(a, b)
    if #a.msgid ~= #b.msgid then return #a.msgid > #b.msgid end
    return a.id < b.id
  end)
end

function M.get(domain)
  if not valid_domain(domain) then return nil, 'invalid domain' end
  if loaded[domain] then
    return loaded[domain].catalog, loaded[domain].error
  end
  local registration = registrations[domain]
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
  loaded = {}
  local count = 0
  for _, registration in pairs(registrations) do
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
    build(source, domain)
  end
  return vim.deepcopy(sources)
end

function M.use_sources(sources)
  local old = bundled_sources
  bundled_sources = sources
  for domain, registration in pairs(registrations) do
    if registration.module then loaded[domain] = nil end
  end
  return old
end

function M.validate_overrides(value) return validate_overrides(value) end

return M
