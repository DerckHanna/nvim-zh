local M = {}

local config = { enabled = true, max_entries = 2000 }
local function queue() return { rows = {}, size = 0 } end
local entries, hits = queue(), queue()
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

local function remove(list, entry)
  if not entry then return end
  local previous, next_entry = entry.previous, entry.next
  if previous then previous.next = next_entry else list.first = next_entry end
  if next_entry then next_entry.previous = previous else list.last = previous end
  list.rows[entry.key] = nil
  list.size = list.size - 1
end

local function append(list, entry)
  if list.last then list.last.next = entry else list.first = entry end
  entry.previous, entry.next = list.last, nil
  list.last, list.rows[entry.key] = entry, entry
  list.size = list.size + 1
end

local function evict(list)
  remove(list, list.first)
  if list == entries then dropped_missing = dropped_missing + 1 else dropped_hits = dropped_hits + 1 end
end

function M.configure(value)
  value = value or {}
  config.enabled = value.enabled ~= false
  config.max_entries = value.max_entries or 2000
  while entries.size > config.max_entries do evict(entries) end
  while hits.size > config.max_entries do evict(hits) end
end

function M.reset()
  entries, hits = queue(), queue()
  totals = { observed = 0, translated = 0, fallback = 0 }
  dropped_missing = 0
  dropped_hits = 0
end

function M.observe(spec)
  if not config.enabled then return end
  local key, stored = key_for(spec.domain, spec.context or '', spec.msgid, spec.dynamic)
  local counter = spec.translated and 'translated' or 'fallback'
  totals.observed = totals.observed + 1
  totals[counter] = totals[counter] + 1
  if spec.translated then
    remove(entries, entries.rows[key])
    remove(hits, hits.rows[key])
    if hits.size >= config.max_entries then evict(hits) end
    append(hits, { key = key })
    return
  end
  remove(hits, hits.rows[key])
  local entry = entries.rows[key]
  remove(entries, entry)
  if entries.size >= config.max_entries then evict(entries) end
  entry = entry or { domain = spec.domain, context = spec.context or '', key = key, msgid = stored,
    count = 0, dynamic = spec.dynamic or false }
  entry.count = entry.count + 1
  append(entries, entry)
end

function M.list()
  local rows = {}
  for _, entry in pairs(entries.rows) do
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
  local missing_unique, translated_unique = entries.size, hits.size
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
