local M = {}
local engine = require('nvim-zh.engine')

function M.match_message(domain, body, code, level, interface)
  if domain == 'clang' and level == 'note' and interface == 'quickfix' then
    local conjunction, expression, diagnostic = body:match("^([a-z]+) '([^']+)' would be invalid: (.+)$")
    if conjunction == 'because' or conjunction == 'and' then
      local nested, status, nested_id = engine.translate({
        domain = domain, context = 'substitution_diagnostic', msgid = diagnostic,
        formatted = true, observe = false, report_ambiguity = true,
      })
      if status == 'ambiguous' then return body, status end
      if status == 'translated' then
        local text, reason, id = engine.translate({
          domain = domain, context = 'note', msgid = conjunction .. " '%1' would be invalid: %2",
          args = { ['1'] = expression, ['2'] = nested }, observe = false,
        })
        if reason == 'translated' then return text, reason, 'note', id, nested_id end
      end
    end
  end
  local contexts = {}
  if interface == 'include_stack' then
    contexts[1] = 'include_stack'
  elseif domain == 'clang-tidy' then
    if code then contexts[1] = level == 'note' and code .. '/note' or code end
    if level == 'note' then
      if code and code:match('^clang%-analyzer%-') then contexts[#contexts + 1] = 'analyzer_note' end
      contexts[#contexts + 1] = 'fix_note'
      if code and code:match('^clang%-analyzer%-') then contexts[#contexts + 1] = code end
    end
  else
    local warning = code and (code:match(',(%-W[^,]+)$') or code)
    if warning then contexts[#contexts + 1] = warning end
    if interface == 'driver' then
      contexts[#contexts + 1] = 'driver'
      contexts[#contexts + 1] = 'unlocated'
    end
    if level == 'note' then
      contexts[#contexts + 1] = 'note'
    else
      if body:match('^too few template arguments for ') or body:match('^too many template arguments for ') then
        contexts[#contexts + 1] = 'template_arity'
      end
      contexts[#contexts + 1] = 'diagnostic'
    end
  end
  for _, context in ipairs(contexts) do
    local result, status, id = engine.translate({
      domain = domain, context = context, msgid = body, formatted = true, observe = false, report_ambiguity = true,
    })
    if status == 'ambiguous' then return body, status end
    if status == 'translated' then return result, status, context, id end
  end
  return body, 'missing_translation'
end

return M
