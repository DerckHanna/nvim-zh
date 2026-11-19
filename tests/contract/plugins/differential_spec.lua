local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal = h.check, h.equal
local index = require('nvim-zh.adapters.index')
if not index['which-key'] or not index.telescope then
  print('PLUGIN_DIFFERENTIAL_SPEC=NOT_APPLICABLE which-key/Telescope combination absent')
  return
end

-- Absent plugins must remain absent; no adapter may force require/preload.
for _, name in ipairs({ 'which-key.config', 'telescope.pickers', 'telescope.pickers.window', 'nvim-tree', 'dap', 'dap.ui', 'dap.repl', 'dapui', 'dapui.render.canvas', 'nio.ui' }) do
  package.loaded[name] = nil
end
local preload_calls = 0
for _, name in ipairs({ 'which-key.config', 'telescope.pickers', 'telescope.pickers.window', 'nvim-tree', 'dap', 'dap.ui', 'dap.repl', 'dapui', 'dapui.render.canvas', 'nio.ui' }) do
  package.preload[name] = function() preload_calls = preload_calls + 1; error('forced load: ' .. name) end
end
h.setup()
equal(preload_calls, 0, 'adapter forced an absent plugin to load')
local absent = require('nvim-zh').status().adapters
check(not absent['which-key'].active and absent['which-key'].reason == 'not_loaded', 'absent which-key state')
check(not absent.telescope.active and absent.telescope.reason == 'not_loaded', 'absent Telescope state')
for id, spec in pairs(index) do
  if spec.status == 'implemented' then check(not absent[id].active, id .. ' falsely active without module') end
end
for _, name in ipairs({ 'which-key.config', 'telescope.pickers', 'telescope.pickers.window', 'nvim-tree', 'dap', 'dap.ui', 'dap.repl', 'dapui', 'dapui.render.canvas', 'nio.ui' }) do
  package.preload[name] = nil
end

local wk_config = { replace = { key = {}, desc = { { '^%+', '' } } } }
package.loaded['which-key.config'] = wk_config
local view = { replace = function(field, value)
  for _, replacement in pairs(wk_config.replace[field]) do
    value = type(replacement) == 'function' and (replacement(value) or value)
      or value:gsub(replacement[1], replacement[2])
  end
  return value
end }
package.loaded['which-key.view'] = view
local picker_calls = {}
local pickers = {}
local original_new = function(opts, defaults)
  table.insert(picker_calls, { opts = opts, defaults = defaults })
  local result = {}
  for key, value in pairs(defaults or {}) do result[key] = value end
  for key, value in pairs(opts or {}) do result[key] = value end
  return result
end
pickers.new = original_new
package.loaded['telescope.pickers'] = pickers
local window = {}
window.get_initial_window_options = function(picker)
  return {
    prompt = { title = picker.prompt_title, enter = true },
    results = { title = picker.results_title, enter = false },
    preview = { title = picker.preview_title, enter = false },
  }
end
package.loaded['telescope.pickers.window'] = window

local mapping = { lhs = '<leader>x', rhs = ':echo 1<CR>', desc = 'Delete', mode = 'n' }
local finder = { id = 1 }
local entry = { value = 'raw-entry', ordinal = 'raw-entry' }
local entry_maker = function() return entry end
local function run()
  picker_calls = {}
  local desc = view.replace('desc', mapping.desc)
  local key = view.replace('key', mapping.lhs)
  local picker = pickers.new({ finder = finder }, {
    prompt_title = 'Find Files', results_title = 'Results', entry_maker = entry_maker,
  })
  local projection = window.get_initial_window_options(picker)
  return {
    desc = desc,
    key = key,
    mapping_same = mapping.lhs == '<leader>x' and mapping.rhs == ':echo 1<CR>' and mapping.desc == 'Delete',
    picker = picker,
    projection = projection,
    finder_same = picker.finder == finder,
    entry_same = picker.entry_maker() == entry,
    opts = picker_calls[1].opts,
    defaults = picker_calls[1].defaults,
  }
end

h.setup({ auto = false, disabled = {} })
local baseline = run()
h.setup()
local translated = run()
equal(translated.desc, '删除', 'which-key display description was not translated')
equal(translated.projection.prompt.title, '查找文件', 'Telescope display prompt was not translated')
equal(translated.projection.results.title, '结果', 'Telescope default results title was not translated')
equal(translated.picker.prompt_title, 'Find Files', 'picker internal prompt changed')
equal(translated.picker.results_title, 'Results', 'picker internal results changed')
baseline.desc, translated.desc = '<display>', '<display>'
baseline.projection, translated.projection = '<display>', '<display>'
check(vim.deep_equal(baseline, translated), 'plugin non-display behavior differs:\n' .. vim.inspect({ baseline = baseline, translated = translated }))

local samples = { '', '你好 🌏', 'line one\nline two', string.rep('long-文本-', 10000), '%s {name} %%' }
for _, sample in ipairs(samples) do
  equal(view.replace('desc', sample), sample, 'which-key fuzzy fallback')
  local picker = pickers.new({ prompt_title = sample }, {})
  equal(window.get_initial_window_options(picker).prompt.title, sample, 'Telescope fuzzy fallback')
  equal(picker.prompt_title, sample, 'fallback mutated internal title')
end

local clock = vim.uv.hrtime
local iterations = 5000
local function measure(title)
  local started = clock()
  for _ = 1, iterations do
    local picker = pickers.new({ prompt_title = title }, {})
    window.get_initial_window_options(picker)
  end
  return (clock() - started) / 1000 / iterations
end
h.setup({ auto = true, disabled = { 'telescope' } })
local baseline_us = measure('Find Files')
h.setup()
for _ = 1, 100 do pickers.new({ prompt_title = 'Find Files' }, {}) end
local hit_us = measure('Find Files')
local miss_us = measure('Unknown performance title')
print(('PLUGIN_ADAPTER_PERF baseline_us=%.3f cache_hit_us=%.3f cache_miss_us=%.3f iterations=%d'):format(
  baseline_us, hit_us, miss_us, iterations))
print('PLUGIN_DIFFERENTIAL_SPEC=PASS non_display=identical internal_titles=preserved no_forced_load=true')
