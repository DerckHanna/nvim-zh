local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/phase4/helpers.lua')
local check, equal = h.check, h.equal

local user_calls = 0
local config = { replace = { key = {}, desc = {
  function(value)
    user_calls = user_calls + 1
    return value == 'user-source' and 'Save File' or value
  end,
  { '^%+', '' },
} } }
package.loaded['which-key.config'] = config
package.loaded['which-key.view'] = {
  replace = function(field, value)
    for _, replacement in pairs(config.replace[field]) do
      value = type(replacement) == 'function' and (replacement(value) or value)
        or value:gsub(replacement[1], replacement[2])
    end
    return value
  end,
}
local view = package.loaded['which-key.view']
local mapping = { lhs = '<leader>sf', rhs = ':write<CR>', desc = 'Save File', buffer = 7 }
local original_desc_count = #config.replace.desc
h.setup()
equal(#config.replace.desc, original_desc_count + 1, 'which-key desc formatter not installed')
local info = require('nvim-zh').info().plugins['which-key']
check(info.active and info.seam == 'replace.desc', 'which-key active capability missing')
equal(view.replace('desc', mapping.desc), '保存文件', 'which-key desc translation')
equal(view.replace('desc', 'user-source'), '保存文件', 'user formatter chaining')
equal(view.replace('desc', '+Open'), '打开', 'pattern formatter ordering')
equal(view.replace('desc', 'Unknown mapping'), 'Unknown mapping', 'unknown mapping fallback')
equal(view.replace('key', '<leader>sf'), '<leader>sf', 'key changed')
check(mapping.lhs == '<leader>sf' and mapping.rhs == ':write<CR>' and mapping.desc == 'Save File' and mapping.buffer == 7,
  'mapping spec was mutated')
equal(user_calls, 4, 'user desc formatter call count')

h.setup()
equal(#config.replace.desc, original_desc_count + 1, 'repeated setup duplicated desc formatter')
require('nvim-zh').reload()
equal(#config.replace.desc, original_desc_count + 1, 'reload duplicated desc formatter')
equal(view.replace('desc', 'Save File'), '保存文件', 'reload translation')

local engine = require('nvim-zh.engine')
local original_translate = engine.translate
engine.translate = function() error('which-key translation error') end
equal(view.replace('desc', 'Save File'), 'Save File', 'translation exception fallback')
engine.translate = original_translate

local external = function(value) return 'External ' .. value end
table.insert(config.replace.desc, external)
local owned_formatter = config.replace.desc[original_desc_count + 1]
h.setup({ auto = true, disabled = { 'which-key' } })
equal(#config.replace.desc, original_desc_count + 1, 'disable did not remove only owned formatter')
check(config.replace.desc[#config.replace.desc] == external, 'disable removed external formatter')
equal(view.replace('desc', 'Save File'), 'External Save File', 'disabled which-key still translated')
equal(owned_formatter('Save File'), 'Save File', 'retained which-key formatter remained active after disable')
print('WHICH_KEY_ADAPTER_SPEC=PASS seam=replace.desc mapping=unchanged')
