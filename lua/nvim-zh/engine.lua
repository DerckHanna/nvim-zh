local M = {}

local catalog = require('nvim-zh.catalog')
local missing = require('nvim-zh.missing')
local SEP = catalog._key_separator()
local MAX_TEMPLATE_INPUT = 8192
local unpack = table.unpack or unpack
local matchers = setmetatable({}, { __mode = 'k' })
local probes = setmetatable({}, { __mode = 'k' })
local groups = setmetatable({}, { __mode = 'k' })
local specificities = setmetatable({}, { __mode = 'k' })

local function flush_literal(tokens, buffer)
  if #buffer > 0 then
    table.insert(tokens, { literal = table.concat(buffer) })
    for index = 1, #buffer do buffer[index] = nil end
  end
end

local function parse_template(text, clangd)
  local tokens, buffer, placeholders = {}, {}, {}
  local kind
  local index = 1
  while index <= #text do
    local char = text:sub(index, index)
    local name = text:match('^{([%a_][%w_]*)}', index)
    if name then
      flush_literal(tokens, buffer)
      if kind and kind ~= 'named' then return nil end
      kind = 'named'
      local raw = '{' .. name .. '}'
      table.insert(tokens, { kind = 'named', name = name, raw = raw })
      table.insert(placeholders, name)
      index = index + #raw
    elseif char == '%' then
      if text:sub(index, index + 1) == '%%' then
        table.insert(buffer, '%')
        index = index + 2
      else
        -- Clang diagnostic argument: exactly one digit (%0-%9). The runtime
        -- FormatDiagnostic reads a single digit, so well-formed catalog
        -- templates never contain multi-digit argument placeholders.
        local digit = text:sub(index + 1, index + 1)
        if clangd and digit:match('^%d$') and not text:sub(index + 2, index + 2):match('%d') then
          flush_literal(tokens, buffer)
          if kind and kind ~= 'index' then return nil end
          kind = 'index'
          local raw = '%' .. digit
          table.insert(tokens, { kind = 'named', name = digit, raw = raw })
          table.insert(placeholders, digit)
          index = index + 2
        else
          local flags, width, precision, conversion
          if clangd then
            flags, width, precision = '', '', ''
            conversion = text:match('^%%([ds])', index)
          else
            flags, width, precision, conversion = text:match('^%%([-+ #0]*)(%d*)(%.?%d*)([diufeEgGxXoscq])', index)
          end
          if not conversion then
            table.insert(buffer, char)
            index = index + 1
          else
            flush_literal(tokens, buffer)
            if kind and kind ~= 'printf' then return nil end
            kind = 'printf'
            local raw = '%' .. flags .. width .. precision .. conversion
            table.insert(tokens, { kind = 'printf', conversion = conversion, raw = raw })
            table.insert(placeholders, conversion)
            index = index + #raw
          end
        end
      end
    else
      table.insert(buffer, char)
      index = index + 1
    end
  end
  flush_literal(tokens, buffer)
  if #placeholders == 0 then return nil end
  return { tokens = tokens, placeholders = placeholders, kind = kind }
end

local function compatible(source, target)
  if not source or not target or source.kind ~= target.kind
    or #source.placeholders ~= #target.placeholders then return false end
  if source.kind == 'printf' then
    for index, conversion in ipairs(source.placeholders) do
      if target.placeholders[index] ~= conversion then return false end
    end
    return true
  end
  local counts = {}
  for _, name in ipairs(source.placeholders) do counts[name] = (counts[name] or 0) + 1 end
  for _, name in ipairs(target.placeholders) do
    counts[name] = (counts[name] or 0) - 1
    if counts[name] < 0 then return false end
  end
  for _, count in pairs(counts) do if count ~= 0 then return false end end
  return true
end

local function render_named(template, values)
  local output = {}
  for _, token in ipairs(template.tokens) do
    if token.literal then
      table.insert(output, token.literal)
    else
      local value = values[token.name]
      if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
      table.insert(output, tostring(value))
    end
  end
  return table.concat(output)
end

local function format_entry(entry, args, clangd)
  local source = parse_template(entry.msgid, clangd)
  if not source then return entry.msgstr end
  local target = parse_template(entry.msgstr, clangd)
  if not compatible(source, target) or type(args) ~= 'table' then return nil end
  if source.kind ~= 'printf' then return render_named(target, args) end
  if #args ~= #source.placeholders then return nil end
  for index = 1, #args do
    if args[index] == nil then return nil end
  end
  local ok, result = pcall(string.format, entry.msgstr, unpack(args, 1, #args))
  return ok and result or nil
end

local function escape_literal(text)
  return (text:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

local function capture_pattern(token)
  if token.conversion == 's' or token.conversion == 'q' then return '(.-)' end
  if token.conversion == 'c' then return '(.)' end
  if token.conversion:match('[diuxXo]') then return '([%-%+]?%d+)' end
  return '([%-%+]?%d+%.?%d*[eE]?[%-%+]?%d*)'
end

local function printf_runs(template)
  local runs = {}
  for _, token in ipairs(template.tokens) do
    local previous = runs[#runs]
    if token.literal then
      runs[#runs + 1] = token
    elseif previous and previous.size then
      previous.size = previous.size + 1
    else
      runs[#runs + 1] = { size = 1, token = token }
    end
  end
  return runs
end

local function compile_matcher(entry, clangd, domain)
  local source = parse_template(entry.msgid, clangd)
  local target = parse_template(entry.msgstr, clangd)
  if not compatible(source, target) then return nil end

  if source.kind ~= 'printf' then
    local pattern, literal_bytes, raw_quoted = { '^' }, 0, false
    local overload_conversion = clangd and source.kind == 'index'
      and entry.msgid:lower():match('^candidate .+ not viable: no known conversion ')
    for index, token in ipairs(source.tokens) do
      if token.literal then
        literal_bytes = literal_bytes + #token.literal
        local first = token.literal:sub(1, 1)
        if clangd and index == 1 and first:match('^[A-Za-z]$') then
          -- clangd capitalizes the first byte of a composed diagnostic.
          pattern[#pattern + 1] = '[' .. first:lower() .. first:upper() .. ']'
          pattern[#pattern + 1] = escape_literal(token.literal:sub(2))
        else
          pattern[#pattern + 1] = escape_literal(token.literal)
        end
      else
        local previous, following = source.tokens[index - 1], source.tokens[index + 1]
        if previous and not previous.literal and source.kind ~= 'index' then return nil end
        local quoted = clangd and previous and previous.literal and following and following.literal
          and previous.literal:sub(-1) == "'" and following.literal:sub(1, 1) == "'"
        -- This driver message quotes the complete path, including any
        -- apostrophes in its name. Suggestions use a separate form ending '?'.
        raw_quoted = quoted and domain == 'clang' and entry.context == 'driver' and #source.placeholders == 1
          and entry.msgid == "no such file or directory: '%0'"
        if previous and not previous.literal then
          pattern[#pattern + 1] = '()'
        else
          pattern[#pattern + 1] = quoted and not raw_quoted and "([^']*)" or '(.-)'
        end
      end
    end
    -- Bare Clang arguments can contain entire user messages, such as #error.
    if source.kind == 'index' and domain ~= 'clang-tidy' and literal_bytes < 8 then return nil end
    pattern[#pattern + 1] = '$'
    local probe = ''
    for index, token in ipairs(source.tokens) do
      if token.literal then
        local lit = (clangd and index == 1 and token.literal:sub(1, 1):match('^[A-Za-z]$'))
          and token.literal:sub(2) or token.literal
        if #lit > #probe then probe = lit end
      end
    end
    probes[entry] = probe
    specificities[entry] = literal_bytes
    local adj_next = {}
    local p_idx = 0
    for ti, tok in ipairs(source.tokens) do
      if not tok.literal then
        p_idx = p_idx + 1
        if source.tokens[ti + 1] and not source.tokens[ti + 1].literal then
          adj_next[p_idx] = true
        end
      end
    end
    local anchor = table.concat(pattern)
    return function(text)
      if probe ~= '' and not text:find(probe, 1, true) then return nil end
      local captures = { text:match(anchor) }
      if #captures ~= #source.placeholders then return nil end
      local values = {}
      for index, name in ipairs(source.placeholders) do
        local value = captures[index]
        if adj_next[index] then
          local next_name = source.placeholders[index + 1]
          if values[name] ~= nil then
            if value:sub(1, #values[name]) ~= values[name] then return nil end
            captures[index + 1] = value:sub(#values[name] + 1)
            value = values[name]
          elseif next_name and values[next_name] ~= nil then
            local suffix = values[next_name]
            if #value < #suffix or value:sub(-#suffix) ~= suffix then return nil end
            captures[index + 1] = suffix
            value = value:sub(1, #value - #suffix)
          else
            captures[index + 1] = ''
          end
        end
        if overload_conversion then
          if (name == '3' or name == '4') and value:sub(1, 1) ~= "'" then return nil end
          if name == '6' then
            local suffix = value:match('^%d+(%a%a)$')
            if suffix ~= 'st' and suffix ~= 'nd' and suffix ~= 'rd' and suffix ~= 'th' then return nil end
          end
        end
        -- A single argument must not consume another quoted diagnostic clause.
        if source.kind == 'index' and not raw_quoted and value:find("'", 1, true) and not value:match("^'[^']*'$")
          and not value:match("^'[^']*' %(aka '[^']*'%)$") then
          return nil
        end
        if values[name] ~= nil and values[name] ~= value then return nil end
        values[name] = value
      end
      return render_named(target, values)
    end
  end

  local source_runs, target_runs = printf_runs(source), printf_runs(target)
  local pattern, sizes, literal_bytes, probe = { '^' }, {}, 0, ''
  for _, run in ipairs(source_runs) do
    if run.literal then
      literal_bytes = literal_bytes + #run.literal
      if #run.literal > #probe then probe = run.literal end
      pattern[#pattern + 1] = escape_literal(run.literal)
    else
      sizes[#sizes + 1] = run.size
      -- A run has no internal delimiter. Capture the entire byte sequence.
      pattern[#pattern + 1] = run.size == 1 and capture_pattern(run.token) or '(.-)'
    end
  end
  pattern[#pattern + 1] = '$'
  local capture = 0
  for _, run in ipairs(target_runs) do
    if not run.literal then
      capture = capture + 1
      -- A translation cannot split or join runs unless given the original args.
      if sizes[capture] ~= run.size then return nil end
    end
  end
  probes[entry] = probe
  specificities[entry] = literal_bytes
  local anchor = table.concat(pattern)
  return function(text)
    local captures = { text:match(anchor) }
    if #captures ~= #sizes then return nil end
    local output, index = {}, 0
    for _, run in ipairs(target_runs) do
      if run.literal then
        output[#output + 1] = run.literal
      else
        index = index + 1
        output[#output + 1] = captures[index]
      end
    end
    return table.concat(output)
  end
end

local function match_template(entry, text, clangd, domain)
  local matcher = matchers[entry]
  if matcher == nil then
    matcher = compile_matcher(entry, clangd, domain) or false
    matchers[entry] = matcher
  end
  if matcher then return matcher(text) end
end

local function observe(spec, translated)
  if spec.observe == false then return end
  missing.observe({
    domain = spec.domain,
    context = spec.context or '',
    msgid = spec.msgid,
    dynamic = spec.formatted == true,
    translated = translated,
  })
end

local function translate(spec)
  if type(spec) ~= 'table' or type(spec.msgid) ~= 'string' then return '', 'fallback', nil end
  local original = spec.msgid
  if original == '' then return original, 'fallback', nil end
  if spec.translated == true then return original, 'translated', spec.entry_id end
  if type(spec.domain) ~= 'string' or (spec.context ~= nil and type(spec.context) ~= 'string') then
    return original, 'fallback', nil
  end
  local context = spec.context or ''
  local clangd = spec.domain == 'clangd' or spec.domain == 'clang' or spec.domain == 'clang-tidy'
  local current = catalog.get(spec.domain)
  if not current then
    observe(spec, false)
    return original, 'fallback', nil
  end
  local translated_id = current.translated[context .. SEP .. original] or current.translated['' .. SEP .. original]
  if translated_id then return original, 'translated', translated_id end

  local entry = current.exact[context .. SEP .. original] or current.exact['' .. SEP .. original]
  if entry then
    local result = format_entry(entry, spec.args, clangd)
    if result then
      observe(spec, true)
      return result, 'translated', entry.id
    end
    -- A formatted diagnostic may itself contain placeholder-like source text.
    -- Let the anchored matcher capture it verbatim instead of treating it as
    -- an unformatted template invocation with missing arguments.
    if spec.formatted ~= true then
      observe(spec, false)
      return original, 'fallback', nil
    end
  end

  if spec.formatted == true and #original <= MAX_TEMPLATE_INPUT then
    local function scan(candidates)
      if not candidates then return nil, nil, false end
      local matched, matched_entry, best_spec, best_index, ambiguous = nil, nil, -1, 0, false
      local function match(candidate, index)
        local probe = probes[candidate]
        if probe and probe ~= '' and not original:find(probe, 1, true) then return end
        local result = match_template(candidate, original, clangd, spec.domain)
        if not result then return end
        local specificity = specificities[candidate] or 0
        if specificity > best_spec then
          matched, matched_entry, best_spec, best_index, ambiguous = result, candidate, specificity, index, false
        elseif specificity == best_spec then
          if matched ~= result then ambiguous = true end
          if index < best_index then matched, matched_entry, best_index = result, candidate, index end
        end
      end
      if #candidates <= 64 then
        for index, candidate in ipairs(candidates) do match(candidate, index) end
      else
        local group = groups[candidates]
        if not group then
          group = { prefixes = {}, unindexed = {} }
          for index, candidate in ipairs(candidates) do
            match_template(candidate, '', clangd, spec.domain)
            local probe = probes[candidate] or ''
            if #probe >= 4 then
              local prefix = probe:sub(1, 4)
              local bucket = group.prefixes[prefix] or {}
              group.prefixes[prefix] = bucket
              bucket[#bucket + 1] = index
            else
              group.unindexed[#group.unindexed + 1] = index
            end
          end
          groups[candidates] = group
        end
        for _, index in ipairs(group.unindexed) do match(candidates[index], index) end
        local seen = {}
        for position = 1, #original - 3 do
          local bucket = group.prefixes[original:sub(position, position + 3)]
          if bucket and not seen[bucket] then
            seen[bucket] = true
            for _, index in ipairs(bucket) do match(candidates[index], index) end
          end
        end
      end
      if ambiguous then return nil, nil, true end
      return matched, matched_entry, false
    end
    local first_byte = catalog._template_key(original)
    local function match_context(template_context)
      local buckets = current.template_buckets[template_context]
      if not buckets then return nil, nil, false end
      local matched, matched_entry, ambiguous = scan(buckets[first_byte])
      if matched or ambiguous then return matched, matched_entry, ambiguous end
      -- A rendered argument can start with the template's leading literal, so
      -- templates whose msgid begins with a placeholder share the '' bucket and
      -- are only consulted when no literal-anchored template matched.
      return scan(buckets[''])
    end
    local matched, matched_entry, ambiguous = match_context(context)
    if not matched and not ambiguous and context ~= '' then
      matched, matched_entry, ambiguous = match_context('')
    end
    if ambiguous then
      observe(spec, false)
      return original, spec.report_ambiguity and 'ambiguous' or 'fallback', nil
    end
    if matched then
      observe(spec, true)
      return matched, 'translated', matched_entry.id
    end
  end
  observe(spec, false)
  return original, 'fallback', nil
end

function M.setup(config)
  catalog.configure(config)
  missing.configure(config.missing)
end

function M.translate(spec)
  local original = type(spec) == 'table' and type(spec.msgid) == 'string' and spec.msgid or ''
  local ok, text, status, id = pcall(translate, spec)
  if ok then return text, status, id end
  return original, 'fallback', nil
end

function M.stats()
  local stats = missing.stats()
  stats.static = { domains = catalog.inventory() }
  return stats
end

return M
