local M = {}

local catalog = require('nvim-zh.catalog')
local missing = require('nvim-zh.missing')
local SEP = catalog._key_separator()
local MAX_TEMPLATE_INPUT = 8192
local unpack = table.unpack or unpack

local function flush_literal(tokens, buffer)
  if #buffer > 0 then
    table.insert(tokens, { literal = table.concat(buffer) })
    for index = 1, #buffer do buffer[index] = nil end
  end
end

local function parse_template(text)
  local tokens, buffer, placeholders = {}, {}, {}
  local kind
  local index = 1
  while index <= #text do
    local char = text:sub(index, index)
    local name = text:match('^{([%a_][%w_]*)}', index)
    if name then
      flush_literal(tokens, buffer)
      if kind == 'printf' then return nil end
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
        local flags, width, precision, conversion = text:match('^%%([-+ #0]*)(%d*)(%.?%d*)([diufeEgGxXoscq])', index)
        if not conversion then
          table.insert(buffer, char)
          index = index + 1
        else
          flush_literal(tokens, buffer)
          if kind == 'named' then return nil end
          kind = 'printf'
          local raw = '%' .. flags .. width .. precision .. conversion
          table.insert(tokens, { kind = 'printf', conversion = conversion, raw = raw })
          table.insert(placeholders, conversion)
          index = index + #raw
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

local function format_entry(entry, args)
  local source = parse_template(entry.msgid)
  if not source then return entry.msgstr end
  local target = parse_template(entry.msgstr)
  if not compatible(source, target) or type(args) ~= 'table' then return nil end
  if source.kind == 'named' then return render_named(target, args) end
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
  if token.kind == 'named' or token.conversion == 's' or token.conversion == 'q' then return '(.-)' end
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

local function match_template(entry, text)
  local source = parse_template(entry.msgid)
  local target = parse_template(entry.msgstr)
  if not compatible(source, target) then return nil end

  if source.kind == 'named' then
    local pattern = { '^' }
    for index, token in ipairs(source.tokens) do
      if token.literal then
        table.insert(pattern, escape_literal(token.literal))
      else
        -- Two names without a delimiter cannot be recovered from rendered text.
        if index > 1 and not source.tokens[index - 1].literal then return nil end
        table.insert(pattern, capture_pattern(token))
      end
    end
    table.insert(pattern, '$')
    local captures = { text:match(table.concat(pattern)) }
    if #captures ~= #source.placeholders then return nil end
    local values = {}
    for index, name in ipairs(source.placeholders) do
      if values[name] ~= nil and values[name] ~= captures[index] then return nil end
      values[name] = captures[index]
    end
    return render_named(target, values)
  end

  local source_runs, target_runs = printf_runs(source), printf_runs(target)
  local pattern, sizes = { '^' }, {}
  for _, run in ipairs(source_runs) do
    if run.literal then
      pattern[#pattern + 1] = escape_literal(run.literal)
    else
      sizes[#sizes + 1] = run.size
      -- A run has no internal delimiter. Capture the entire byte sequence.
      pattern[#pattern + 1] = run.size == 1 and capture_pattern(run.token) or '(.-)'
    end
  end
  pattern[#pattern + 1] = '$'
  local captures = { text:match(table.concat(pattern)) }
  if #captures ~= #sizes then return nil end

  local output, capture = {}, 0
  for _, run in ipairs(target_runs) do
    if run.literal then
      output[#output + 1] = run.literal
    else
      capture = capture + 1
      -- A translation cannot split or join runs unless given the original args.
      if sizes[capture] ~= run.size then return nil end
      output[#output + 1] = captures[capture]
    end
  end
  return table.concat(output)
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
  local current = catalog.get(spec.domain)
  if not current then
    observe(spec, false)
    return original, 'fallback', nil
  end
  local translated_id = current.translated[context .. SEP .. original] or current.translated['' .. SEP .. original]
  if translated_id then return original, 'translated', translated_id end

  local entry = current.exact[context .. SEP .. original] or current.exact['' .. SEP .. original]
  if entry then
    local result = format_entry(entry, spec.args)
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
    local function match_context(template_context)
      local matched, matched_entry
      for _, candidate in ipairs(current.templates) do
        if candidate.context == template_context then
          local result = match_template(candidate, original)
          if result then
            if matched then return nil, nil, true end
            matched, matched_entry = result, candidate
          end
        end
      end
      return matched, matched_entry, false
    end
    local matched, matched_entry, ambiguous = match_context(context)
    if not matched and not ambiguous and context ~= '' then
      matched, matched_entry, ambiguous = match_context('')
    end
    if ambiguous then
      observe(spec, false)
      return original, 'fallback', nil
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
