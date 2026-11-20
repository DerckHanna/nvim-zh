local M = {}

local function project_root()
  return require('nvim-zh.paths').root
end
local resource_root
local adapter_enabled = false
local owned_roots, adapter_states = {}, {}

function M.sync_adapters(specs, enabled)
  local desired, states = {}, {}
  if adapter_enabled then
    for id, spec in pairs(specs) do
      if enabled(id) and spec.help then
        states[id] = 'unknown_version'
        for source in pairs(spec.help) do
          local file = vim.api.nvim_get_runtime_file(source, false)[1]
          if file then
            local ok, bytes = pcall(require('nvim-zh.fs').read, file, 4 * 1024 * 1024)
            local hash = ok and vim.fn.sha256(bytes)
            for _, target in pairs(spec.targets) do
              local root = spec.help_root and spec.help_root .. '/' .. vim.fs.basename(source)
              if root and hash and hash == target.sources[source] and vim.uv.fs_stat(root .. '/doc/tags-cn') then
                desired[root] = true
                states[id] = 'active'
                break
              end
            end
          end
        end
      end
    end
  end
  local paths = vim.opt.runtimepath:get()
  for root in pairs(owned_roots) do
    if not desired[root] then vim.opt.runtimepath:remove(root); owned_roots[root] = nil end
  end
  for _, root in ipairs(vim.fn.sort(vim.tbl_keys(desired))) do
    if not vim.tbl_contains(paths, root) then
      vim.opt.runtimepath:prepend(root)
      owned_roots[root] = true
    end
  end
  adapter_states = states
end

function M.adapter_status(id)
  return adapter_states[id] or 'disabled'
end

function M.set_resource_root(root)
  if resource_root == root then return end
  M.sync_adapters({}, function() return false end)
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
  adapter_enabled = config.enabled
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
  return results
end

return M
