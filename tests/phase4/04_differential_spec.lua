local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal

-- Absent plugins must remain absent; no adapter may force require/preload.
package.loaded['which-key.config'] = nil
package.loaded['telescope.pickers'] = nil
local preload_calls = 0
package.preload['which-key.config'] = function() preload_calls = preload_calls + 1 error('forced which-key load') end
package.preload['telescope.pickers'] = function() preload_calls = preload_calls + 1 error('forced Telescope load') end
h.setup()
equal(preload_calls, 0, 'adapter forced an absent plugin to load')
local absent = require('nvim-zh').info().plugins
check(not absent['which-key'].active and absent['which-key'].reason == 'not_loaded', 'absent which-key state')
check(not absent.telescope.active and absent.telescope.reason == 'not_loaded', 'absent Telescope state')

package.preload['which-key.config'] = nil
package.preload['telescope.pickers'] = nil
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

local mapping = { lhs = '<leader>x', rhs = ':echo 1<CR>', desc = 'Save File', mode = 'n' }
local finder = { id = 1 }
local entry = { value = 'raw-entry', ordinal = 'raw-entry' }
local entry_maker = function() return entry end
local function run()
  picker_calls = {}
  local desc = view.replace('desc', mapping.desc)
  local key = view.replace('key', mapping.lhs)
  local picker = pickers.new({ prompt_title = 'Find Files', finder = finder }, {
    results_title = 'Help Tags', entry_maker = entry_maker,
  })
  return {
    desc = desc,
    key = key,
    mapping_same = mapping.lhs == '<leader>x' and mapping.rhs == ':echo 1<CR>' and mapping.desc == 'Save File',
    picker = picker,
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
baseline.desc, translated.desc = '<display>', '<display>'
baseline.picker.prompt_title, translated.picker.prompt_title = '<display>', '<display>'
baseline.picker.results_title, translated.picker.results_title = '<display>', '<display>'
baseline.opts.prompt_title, translated.opts.prompt_title = '<display>', '<display>'
baseline.defaults.results_title, translated.defaults.results_title = '<display>', '<display>'
check(vim.deep_equal(baseline, translated), 'plugin non-display behavior differs:\n' .. vim.inspect({ baseline = baseline, translated = translated }))

local samples = { '', '你好 🌏', 'line one\nline two', string.rep('long-文本-', 10000), '%s {name} %%' }
for _, sample in ipairs(samples) do
  equal(view.replace('desc', sample), sample, 'which-key fuzzy fallback')
  equal(pickers.new({ prompt_title = sample }, {}).prompt_title, sample, 'Telescope fuzzy fallback')
end

local clock = vim.uv and vim.uv.hrtime or vim.loop.hrtime
local iterations = 5000
local function measure(title)
  local started = clock()
  for _ = 1, iterations do pickers.new({ prompt_title = title }, {}) end
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
print('PLUGIN_DIFFERENTIAL_SPEC=PASS non_display=identical no_forced_load=true')
