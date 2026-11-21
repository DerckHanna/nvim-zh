-- Contract for every Neovim help document that nvim-zh ships in doc/*.cnx.
--
-- The assertions are driven entirely by manifests/upstreams.json: adding a
-- document there must not require editing this spec. Everything that can be
-- compared against the real $VIMRUNTIME is only asserted when the running
-- Neovim matches the pinned help baseline, because a different runtime ships
-- different English text and would produce false parity claims. A pinned
-- document the running runtime does not ship at all is reported as
-- "upstream_absent" and skipped, never silently treated as equal.
local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local root = vim.env.NVIM_ZH_ROOT
local function read(path)
  local file = assert(io.open(path, 'rb'), 'cannot read ' .. path)
  local data = file:read('*a')
  file:close()
  return data
end

-- Help tags, using the same rule Neovim's :helptags applies: a "*" that starts
-- the file or follows whitespace, then a run of printable non-whitespace
-- characters, then a "*" that ends the file, ends a line, or is followed by
-- whitespace or another "*". A looser pattern would wrongly collect the "*"
-- characters that appear inside example code and patterns.
local tag_stop = setmetatable({}, { __index = function(_, char)
  return char == ' ' or char == '\t' or char == '\n' or char == '*'
end })

-- Fences, per help.vim start="\%(^\| \)>[a-z0-9]*$". Declared before tags()
-- because the tag scanner has to know where an example block begins.
local function open_fence(line)
  return line:match('^>[a-z0-9]*$') ~= nil or line:match(' >[a-z0-9]*$') ~= nil
end

-- Help tags, using the same rule Neovim's :helptags applies, *including* its
-- rule that a "*tag*" appearing inside an example block is example text and is
-- not indexed. helphelp.txt shows the help-file header format inside such a
-- block (*plugin_name.txt*), so a raw-text scan would demand a tags-cn entry
-- that :helptags never writes. test_help_catalog.py pins that :helptags rule.
local function tags(text)
  local result = {}
  local in_example = false
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    if in_example and not line:match('^[^ \t]') then
      -- Still inside an example body: not a tag position.
    else
      in_example = false
      local cursor = 1
      while true do
        local start = line:find('*', cursor, true)
        if not start then break end
        local previous = start > 1 and line:sub(start - 1, start - 1) or '\n'
        if previous == ' ' or previous == '\t' or previous == '\n' then
          local index = start + 1
          while index <= #line and not tag_stop[line:sub(index, index)] do index = index + 1 end
          if index > start + 1 and index <= #line and line:sub(index, index) == '*' then
            local following = line:sub(index + 1, index + 1)
            if following == '' or following == '\n' or following == ' ' or following == '\t' or following == '*' then
              result[line:sub(start + 1, index - 1)] = true
            end
          end
        end
        cursor = start + 1
      end
      if open_fence(line) then in_example = true end
    end
  end
  return result
end

local function sorted_keys(set)
  local list = {}
  for key in pairs(set) do table.insert(list, key) end
  table.sort(list)
  return list
end

-- Example blocks, using the same rule as Neovim's own help syntax
-- (runtime/syntax/help.vim, region "helpExample"):
--   start="\%(^\| \)>[a-z0-9]*$"  end="^[^ \t]"
-- The block body must stay byte-identical to upstream, including its blank
-- framing lines, so commands inside remain copy-pasteable.
--
-- The "\%(^\| \)" prefix matters: without it a prose line that merely ends in
-- ">" (e.g. "type <Enter>") would be mistaken for a fence, and the block
-- boundaries would drift from help.vim's. Lua patterns have no alternation, so
-- the two branches are tested separately rather than transcribed from the Vim
-- regex (open_fence(), declared above).
local function example_blocks(text)
  local lines = vim.split(text, '\n', { plain = true })
  local blocks, index = {}, 1
  while index <= #lines do
    if not open_fence(lines[index]) then
      index = index + 1
    else
      local body, cursor = {}, index + 1
      while cursor <= #lines and not lines[cursor]:match('^[^ \t]') do
        table.insert(body, lines[cursor])
        cursor = cursor + 1
      end
      table.insert(blocks, table.concat(body, '\n'))
      index = cursor
    end
  end
  return blocks
end

-- Every |help-link| must survive translation, including duplicates: a dropped
-- link silently breaks a cross reference.
local function links(text)
  local counts = {}
  for link in text:gmatch('|([^%s|]+)|') do counts[link] = (counts[link] or 0) + 1 end
  return counts
end

local manifest = vim.json.decode(read(root .. '/manifests/upstreams.json'))
local neovim = assert(manifest.upstreams.neovim, 'manifest lacks neovim upstream')
-- The manifest is the single source of truth for the pinned baseline: this spec
-- must not keep a second, hand-maintained copy of the version or the commit.
check(type(neovim.version) == 'string' and neovim.version:match('^%d+%.%d+%.%d+$') ~= nil,
  'manifest version must be an x.y.z string')
check(type(neovim.commit) == 'string' and #neovim.commit == 40
  and neovim.commit:match('^[0-9a-f]+$') ~= nil,
  'manifest commit must be a 40-character lowercase hex digest')

-- Runtime-independent translation contract: the pinned upstream's tag set,
-- ordered example-block bodies, help-link multiset and file footer, stored as
-- digests in manifests/help_inventory.json by tools/help_inventory.py. A
-- different Neovim may not ship the document at all ($VIMRUNTIME comparisons
-- then cannot run), but the translation must still match the pin, so this is
-- asserted below *before* the pinned guard.
local inventory = vim.json.decode(read(root .. '/manifests/help_inventory.json'))
local contract_by_file = {}
for _, item in ipairs(inventory.documents) do
  contract_by_file[vim.fs.basename(item.path)] = item.contract
end

local version = vim.version()
local running_version = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
-- A build that self-reports the pinned version *and* itself as a prerelease
-- (e.g. "0.12.6-dev") cannot be classified: treating it as unpinned would
-- silently skip every $VIMRUNTIME comparison below. Refuse to guess.
check(not (running_version == neovim.version and version.prerelease),
  ('runtime %s reports the pinned version %s as a prerelease build; '
    .. 'pinned/unpinned cannot be decided'):format(running_version, neovim.version))
local pinned = running_version == neovim.version

-- Parse doc/tags-cn into tag -> file. The third column is a search pattern that
-- escapes backslashes (e.g. *t_CTRL-\_CTRL-O*), so only tag and file are
-- compared here; the search pattern of *both* shipped index files is validated
-- on every version by 03_help_parity_rules_spec.lua (regeneration equality
-- alone is pinned-only).
local tags_cn_file = {}
for line in (read(root .. '/doc/tags-cn') .. '\n'):gmatch('([^\n]*)\n') do
  if line ~= '' then
    local tag, file = line:match('^(.-)\t(.-)\t')
    check(tag ~= nil and file ~= nil, 'malformed tags-cn line: ' .. line)
    check(tags_cn_file[tag] == nil, 'duplicate tag in tags-cn: ' .. tag)
    tags_cn_file[tag] = file
  end
end

local names = sorted_keys(neovim.documents)
check(#names > 0, 'manifest declares no help documents')

local reports = {}
local complete, partial = 0, 0

for _, name in ipairs(names) do
  local meta = neovim.documents[name]
  check(type(meta.source) == 'string' and meta.source ~= '', name .. ': missing source path')
  check(type(meta.translation) == 'string' and meta.translation ~= '', name .. ': missing translation path')
  check(meta.translation:match('^doc/[%w%._%-]+%.cnx$') ~= nil, name .. ': translation must live in doc/ as .cnx')
  check(meta.status == 'complete' or meta.status == 'partial', name .. ': status must be complete or partial')
  check(type(meta.sha256) == 'string' and meta.sha256:match('^[0-9a-f]+$') ~= nil and #meta.sha256 == 64,
    name .. ': sha256 must be a lowercase 64-character digest')
  check(type(meta.notes) == 'string' and meta.notes ~= '', name .. ': a complete/partial note is required')
  if meta.status == 'complete' then complete = complete + 1 else partial = partial + 1 end

  local translated = read(root .. '/' .. meta.translation)
  check(translated:sub(1, 3) ~= '\239\187\191', name .. ': translation must not start with a UTF-8 BOM')
  local translated_tags = sorted_keys(tags(translated))
  check(#translated_tags > 0, name .. ': translation declares no help tag')

  for _, tag in ipairs(translated_tags) do
    equal(tags_cn_file[tag], vim.fs.basename(meta.translation),
      ('tags-cn entry for %q must point at %s'):format(tag, vim.fs.basename(meta.translation)))
  end

  -- A document's own filename tag must exist so ":help <file>.txt" resolves.
  check(tags(translated)[name], name .. ': translation dropped its own file tag')

  -- The tag / example-block / link contract, asserted on *every* version. The
  -- digests come from the pinned upstream, so a deleted tag, a renamed tag, a
  -- rewritten example block or a dropped/invented |link| fails here even on a
  -- runtime that never shipped the document (0.11.5 lacks 10, nightly dropped
  -- pi_zip.txt). Without this the runtime comparison alone was pinned-only and
  -- such a regression passed silently off-pin.
  local translation_contract = contract_by_file[name]
  check(translation_contract ~= nil,
    name .. ': manifests/help_inventory.json carries no translation contract')
  equal(#translated_tags, translation_contract.tag_count, name .. ': tag count changed')
  equal(vim.fn.sha256(table.concat(translated_tags, '\n')), translation_contract.tags_digest,
    name .. ': tag set changed')
  local translated_blocks = example_blocks(translated)
  equal(#translated_blocks, translation_contract.block_count, name .. ': example block count changed')
  local block_digests = {}
  for _, block in ipairs(translated_blocks) do
    table.insert(block_digests, vim.fn.sha256(block))
  end
  equal(vim.fn.sha256(table.concat(block_digests, '\n')), translation_contract.blocks_digest,
    name .. ': example blocks changed')
  local translated_links = links(translated)
  local link_terms = {}
  for _, link in ipairs(sorted_keys(translated_links)) do
    table.insert(link_terms, link .. '\t' .. tostring(translated_links[link]))
  end
  equal(vim.fn.sha256(table.concat(link_terms, '\n')), translation_contract.links_digest,
    name .. ': help links changed')

  -- The footer is structural as well: HELP_TRANSLATION_CONTRACT item 10 requires
  -- the final modeline to be copied byte for byte, and a stray leading space or
  -- an extra trailing newline is invisible to the tag/block/link digests above.
  -- Blank-line predicate must stay identical to footer_bytes() in
  -- tools/help_inventory.py (space, tab, CR, FF - no \v in Lua patterns).
  local function footer(text)
    local rows = vim.split(text, '\n', { plain = true })
    local index = #rows
    while index >= 1 and rows[index]:match('^[ \t\r\f]*$') do index = index - 1 end
    if index < 1 then return '' end
    local slice = {}
    for cursor = index, #rows do table.insert(slice, rows[cursor]) end
    return table.concat(slice, '\n')
  end
  equal(vim.fn.sha256(footer(translated)), translation_contract.tail_digest,
    name .. ': help footer (modeline or trailing lines) changed')

  -- manifest paths are repository-relative ("runtime/doc/<file>"); the
  -- installed runtime is already rooted at "runtime/".
  local relative = meta.source:gsub('^runtime/', '')
  check(relative ~= meta.source, name .. ': source must be a runtime/-relative repository path')
  local upstream_path = vim.env.VIMRUNTIME .. '/' .. relative
  -- Only the pinned baseline must ship every manifest document. A different
  -- runtime may legitimately not ship one at all (0.11.5 lacks 10 of the 133
  -- pinned documents, nightly dropped pi_zip.txt), so a missing upstream copy
  -- skips the *runtime* comparisons for that document instead of failing the
  -- suite: the translation contract asserted above is what this file owns and
  -- it keeps running on every version.
  local upstream_present = vim.fn.filereadable(upstream_path) == 1
  if pinned then
    check(upstream_present, name .. ': pinned source is not present in $VIMRUNTIME')
  end
  local upstream = upstream_present and read(upstream_path) or nil

  if pinned then
    equal(vim.fn.sha256(upstream), meta.sha256, name .. ': installed upstream source differs from manifest')

    local upstream_tags = tags(upstream)
    for tag in pairs(upstream_tags) do
      check(tags(translated)[tag], name .. ': translation missing help tag: ' .. tag)
    end
    for tag in pairs(tags(translated)) do
      check(upstream_tags[tag], name .. ': translation adds unverified help tag: ' .. tag)
    end

    local source_blocks, target_blocks = example_blocks(upstream), example_blocks(translated)
    equal(#target_blocks, #source_blocks, name .. ': example block count changed')
    for index = 1, #source_blocks do
      equal(target_blocks[index], source_blocks[index], name .. ': example block ' .. index .. ' was rewritten')
    end

    local source_links, target_links = links(upstream), links(translated)
    for link, count in pairs(source_links) do
      equal(target_links[link] or 0, count, name .. ': help link changed: ' .. link)
    end
    for link in pairs(target_links) do
      check(source_links[link], name .. ': translation invented a help link: ' .. link)
    end
  end

  table.insert(reports, ('%s[%s%s]'):format(
    name, meta.status, upstream_present and '' or ',upstream_absent'))
end

-- The pinned baseline must be reachable through :help, and an untranslated
-- document must still fall back to the English runtime copy.
require('nvim-zh').setup({ modules = { core = { enabled = false } } })
local opened = {}
for _, name in ipairs(names) do
  local meta = neovim.documents[name]
  -- The file tag ("<name>.txt") is the stable handle every runtime provides.
  local ok = pcall(vim.cmd, 'help ' .. name)
  check(ok, 'help did not open ' .. name)
  local bufname = vim.api.nvim_buf_get_name(0)
  check(bufname:sub(-#meta.translation) == meta.translation,
    'help ' .. name .. ' did not select ' .. meta.translation .. ' (got ' .. bufname .. ')')
  opened[name] = bufname
end
-- The fallback sample must be a document that is *permanently* untranslated,
-- otherwise covering it later turns this into a false failure. api.txt used to
-- serve here and broke the moment api.txt shipped a .cnx; credits.txt is listed
-- in manifests/help_exemptions.json (attribution record, never translated), so
-- English fallback keeps proving the real thing: a tag with no Chinese copy
-- still resolves to the pinned runtime file.
vim.cmd('help credits.txt')
check(vim.api.nvim_buf_get_name(0) == vim.env.VIMRUNTIME .. '/doc/credits.txt',
  'English fallback for credits.txt broke')

print(('HELP_CATALOG_SPEC=PASS documents=%d complete=%d partial=%d pinned=%s list=%s'):format(
  #names, complete, partial, tostring(pinned), table.concat(reports, ',')))
