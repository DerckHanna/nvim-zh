-- Regression guards for the help-parity harness itself (phase 9).
--
-- These do not test a translation directly. They pin the *rules* the other
-- Help specs rely on, because a silent narrowing of a rule turns a parity
-- check into a no-op that still prints PASS:
--
--   * the example-fence predicate must match runtime/syntax/help.vim exactly;
--     an over-broad one shifts block boundaries, an over-narrow one collects no
--     blocks at all and every comparison then trivially succeeds;
--   * the :helptags pattern reconstruction must escape both "\" and "/", and
--     must hold for *both* generated index files: doc/tags is owned by the
--     pinned-only regeneration equality, so before this spec covered it a
--     reviewer could rewrite doc/tags's third column on 0.11.5 and every
--     cross-version guard still passed.
--
-- Both of those bugs actually occurred while translating quickfix.txt,
-- windows.txt and cmdline.txt, so they are pinned here.
local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/ui_helpers.lua')
local check, equal = h.check, h.equal

-- Mirrors open_fence() in 01_help_catalog_spec.lua.
local function open_fence(line)
  return line:match('^>[a-z0-9]*$') ~= nil or line:match(' >[a-z0-9]*$') ~= nil
end

-- Fences, per help.vim start="\%(^\| \)>[a-z0-9]*$".
for _, line in ipairs({
  '>',
  '>lua',
  '>vim',
  '>sh',
  'Example: >',
  'this: >lua',
  '\t\tUseful example: >',
  '\t\t\t\t\t\t*CursorHold-example*  >',
}) do
  check(open_fence(line), ('expected a fence: %q'):format(line))
end

-- Non-fences. Each ends in ">" while being ordinary prose, but with a
-- non-space character directly before the ">". The pre-phase-9 predicate
-- ('>[a-z0-9]*$' with no anchored prefix) accepted these and desynchronised
-- the block list. Note that " >" at end of line *is* a fence per help.vim, so
-- it belongs in the fence list above, not here.
for _, line in ipairs({
  'result.  You will be prompted for the expression, type <Enter>',
  'Use |vim.notify()| to reach the user |lsp|>',
  'matches "pat2" after line containing',
  '>A',
  '> lua',
}) do
  check(not open_fence(line), ('not a fence: %q'):format(line))
end

-- :helptags escapes "\" (doubled) and "/" (backslash-prefixed).
local function tags_pattern(tag)
  return '/*' .. tag:gsub('\\', '\\\\'):gsub('/', '\\/') .. '*'
end
equal(tags_pattern('c_CTRL-R'), '/*c_CTRL-R*', 'plain tag pattern')
equal(tags_pattern('t_CTRL-\\_CTRL-O'), '/*t_CTRL-\\\\_CTRL-O*', 'backslash tag pattern')
equal(tags_pattern('/_<Tab>'), '/*\\/_<Tab>*', 'slash tag pattern')

-- The real generated tags files must agree with that reconstruction, so a
-- future :helptags escaping change surfaces here rather than in a translation.
-- Regeneration equality is pinned-only, so *every* shipped index line is checked
-- here on every Neovim: a wrong search pattern makes ":help <tag>" fail to
-- resolve even though tag and file column still look right.
local function check_tags_file(relative, label, minimum)
  local entered = 0
  for line in io.lines(vim.env.NVIM_ZH_ROOT .. '/' .. relative) do
    if line ~= '' then
      local tag, file, pattern = line:match('^(.-)\t(.-)\t(.*)$')
      check(tag ~= nil, label .. ': malformed line: ' .. line)
      equal(pattern, tags_pattern(tag), ('%s pattern for %s'):format(label, tag))
      check(file ~= nil and file ~= '', label .. ': missing file for tag ' .. tag)
      entered = entered + 1
    end
  end
  check(entered > 0, label .. ' is empty')
  check(entered >= minimum, ('%s lost entries: only %d'):format(label, entered))
  return entered
end

local entered = check_tags_file('doc/tags-cn', 'tags-cn', 1000)
local entered_txt = check_tags_file('doc/tags', 'tags', 1)

print(('HELP_PARITY_RULES_SPEC=PASS tags=%d tags_txt=%d'):format(entered, entered_txt))
