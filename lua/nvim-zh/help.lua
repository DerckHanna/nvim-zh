local M = {}

local function project_root()
  return require('nvim-zh.paths').root
end
local resource_root

function M.set_resource_root(root)
  if resource_root == root then return end
  if resource_root then vim.opt.runtimepath:remove(resource_root) end
  resource_root = root
  if root then vim.opt.runtimepath:prepend(root) end
end

-- Language entries absent before setup are owned by this module. On repeated
-- setup, remove only those entries and preserve languages added by the user.
local owned_langs = {}

local function remove_owned_languages()
  local result, seen = {}, {}
  for _, lang in ipairs(vim.split(vim.o.helplang, ',', { trimempty = true })) do
    if not owned_langs[lang] and not seen[lang] then
      seen[lang] = true
      table.insert(result, lang)
    end
  end
  owned_langs = {}
  return result, seen
end

function M.setup(config)
  if not config.enabled and next(owned_langs) == nil then return end
  local base, base_seen = remove_owned_languages()
  if not config.enabled then
    vim.o.helplang = table.concat(base, ',')
    return
  end
  local result, seen = {}, {}
  local function add(lang, skip_english)
    if lang == '' or seen[lang] or (skip_english and lang == 'en') then return end
    seen[lang] = true
    if not base_seen[lang] then owned_langs[lang] = true end
    table.insert(result, lang)
  end
  for _, lang in ipairs(config.lang) do add(lang, true) end
  for _, lang in ipairs(base) do add(lang, true) end
  add('en', false)
  vim.o.helplang = table.concat(result, ',')
end

function M.info(config)
  local root = resource_root or project_root()
  return {
    enabled = config.enabled,
    helplang = vim.o.helplang,
    chinese_help = root .. '/doc/nvim-zh.cnx',
    tags = root .. '/doc/tags-cn',
  }
end

local function external_chinese_help()
  local own_doc = project_root() .. '/doc'
  own_doc = vim.uv.fs_realpath(own_doc) or own_doc
  for _, path in ipairs(vim.api.nvim_get_runtime_file('doc/usr_01.cnx', true)) do
    local doc = vim.fs.dirname(vim.uv.fs_realpath(path) or path)
    -- Resolve aliases too: a second runtimepath entry pointing at this plugin
    -- does not prove an independent installation. Require a usable help index.
    local active_doc = resource_root and (vim.uv.fs_realpath(resource_root .. '/doc') or resource_root .. '/doc')
    if doc ~= own_doc and doc ~= active_doc then
      local ok, rows = pcall(vim.fn.readfile, doc .. '/tags-cn')
      if ok then
        for _, row in ipairs(rows) do
          if row:find('usr_01.txt\tusr_01.cnx\t', 1, true) == 1 then return true end
        end
      end
    end
  end
  return false
end

function M.check(config)
  local info = M.info(config)
  if not config.enabled then
    return { { name = 'help', status = 'info', message = '中文帮助模块已禁用' } }
  end
  local results = {}
  local tags_readable = vim.fn.filereadable(info.tags) == 1
  table.insert(results, {
    name = 'help.tags',
    status = tags_readable and 'ok' or 'error',
    message = tags_readable and ('已找到 ' .. info.tags) or ('缺少 ' .. info.tags .. '；请检查安装是否完整'),
  })
  local chinese_selected = vim.split(vim.o.helplang, ',', { trimempty = true })[1] == 'cn'
  table.insert(results, {
    name = 'help.helplang',
    status = chinese_selected and 'ok' or 'warn',
    message = chinese_selected and ('helplang=' .. vim.o.helplang) or ('helplang=' .. vim.o.helplang .. '；中文不是首选帮助语言'),
  })
  if config.vimcdoc then
    local found = external_chinese_help()
    table.insert(results, {
      name = 'help.vimcdoc',
      status = found and 'ok' or 'warn',
      message = found and '检测到独立中文帮助资源（Vimcdoc 兼容）'
        or '启用了 vimcdoc 选项，但未检测到带可用索引的独立中文帮助资源',
    })
  end
  return results
end

return M
