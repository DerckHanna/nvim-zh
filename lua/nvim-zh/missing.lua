local M = {}

local config = { enabled = true, max_entries = 2000 }
local entries = {}
local hits = {}
local tick = 0
local totals = { observed = 0, translated = 0, fallback = 0 }
local dropped_missing = 0
local dropped_hits = 0

local function key_for(domain, context, msgid, dynamic)
  -- Match separators rather than ASCII filename characters: paths may contain
  -- only Unicode, and relative/UNC paths need the same privacy treatment.
  local has_path = msgid:find('[/\\][^%s]') ~= nil
    or msgid:find('~[/\\]') ~= nil
    or msgid:find('%a:[\\/]') ~= nil
  local redact = dynamic or has_path or #msgid > 1024
  local label = dynamic and 'dynamic' or 'redacted'
  local stored = redact and ('<' .. label .. ' sha256:' .. vim.fn.sha256(msgid):sub(1, 16) .. '>') or msgid
  return domain .. '\031' .. (context or '') .. '\031' .. stored, stored
end

local function table_size(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

local function evict_one()
  local oldest_key, oldest_tick
  for key, entry in pairs(entries) do
    if oldest_tick == nil or entry.last_used < oldest_tick then
      oldest_key, oldest_tick = key, entry.last_used
    end
  end
  if oldest_key then
    entries[oldest_key] = nil
    dropped_missing = dropped_missing + 1
  end
end

local function evict_hit_one()
  local oldest_key, oldest_tick
  for key, last_used in pairs(hits) do
    if oldest_tick == nil or last_used < oldest_tick then
      oldest_key, oldest_tick = key, last_used
    end
  end
  if oldest_key then
    hits[oldest_key] = nil
    dropped_hits = dropped_hits + 1
  end
end

function M.configure(value)
  value = value or {}
  config.enabled = value.enabled ~= false
  config.max_entries = value.max_entries or 2000
  while table_size(entries) > config.max_entries do evict_one() end
  while table_size(hits) > config.max_entries do evict_hit_one() end
end

function M.reset()
  entries = {}
  hits = {}
  tick = 0
  totals = { observed = 0, translated = 0, fallback = 0 }
  dropped_missing = 0
  dropped_hits = 0
end

function M.observe(spec)
  if not config.enabled then return end
  local key, stored = key_for(spec.domain, spec.context or '', spec.msgid, spec.dynamic)
  tick = tick + 1
  totals.observed = totals.observed + 1
  totals[spec.translated and 'translated' or 'fallback'] = totals[spec.translated and 'translated' or 'fallback'] + 1
  if spec.translated then
    entries[key] = nil
    if hits[key] == nil and table_size(hits) >= config.max_entries then evict_hit_one() end
    hits[key] = tick
    return
  end
  hits[key] = nil
  local entry = entries[key]
  if not entry then
    if table_size(entries) >= config.max_entries then evict_one() end
    entry = {
      domain = spec.domain,
      context = spec.context or '',
      key = key,
      msgid = stored,
      count = 0,
      dynamic = spec.dynamic or false,
    }
    entries[key] = entry
  end
  entry.count = entry.count + 1
  entry.last_used = tick
end

function M.list()
  local rows = {}
  for _, entry in pairs(entries) do
    table.insert(rows, {
      domain = entry.domain,
      context = entry.context,
      key = entry.key,
      msgid = entry.msgid,
      count = entry.count,
      dynamic = entry.dynamic,
    })
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end)
  return rows
end

function M.stats()
  local missing_unique, translated_unique = 0, 0
  for _ in pairs(entries) do missing_unique = missing_unique + 1 end
  for _ in pairs(hits) do translated_unique = translated_unique + 1 end
  local unique = missing_unique + translated_unique
  return {
    missing = {
      unique = missing_unique,
      occurrences = totals.fallback,
      capacity = config.max_entries,
      dropped = dropped_missing,
      enabled = config.enabled,
    },
    runtime = {
      observed = totals.observed,
      translated = totals.translated,
      fallback = totals.fallback,
      unique = unique,
      translated_unique = translated_unique,
      coverage = totals.observed > 0 and totals.translated / totals.observed or 0,
      unique_coverage = unique > 0 and translated_unique / unique or 0,
      dropped_hits = dropped_hits,
      truncated = dropped_missing > 0 or dropped_hits > 0,
    },
  }
end

return M
