local h = dofile(vim.env.NVIM_ZH_ROOT .. '/tests/support/plugin_helpers.lua')
local check, equal, pack = h.check, h.equal, h.pack
local adapter = require('nvim-zh.adapters.which_key')

local po_text = table.concat(vim.fn.readfile(
  vim.env.NVIM_ZH_ROOT .. '/translations/po/zh_CN/which-key.po'), '\n')
for _, forbidden in ipairs({ '窗口', '缓冲区', '寄存器' }) do
  check(not po_text:find(forbidden, 1, true), 'which-key PO contains forbidden term: ' .. forbidden)
end

local enabled = true
local translation_error = false
local translations = {
  Delete = '删除',
  ['Next word'] = '下一个词',
  ['2 keymaps'] = '2 个键映射',
  window = 'Window',
  registers = 'Register',
  ['Last change in current buffer'] = '当前Buffer最后修改',
  ['alternate buffer'] = '备用Buffer',
}
local source = { registrations = 0, releases = 0 }
local ctx = {
  enabled = function() return enabled end,
  translate = function(domain, context, text)
    if translation_error then error('which-key translation error') end
    if domain == 'which-key' and context == 'desc' then return translations[text] or text end
    return text
  end,
  register_source = function(spec)
    source.registrations = source.registrations + 1
    check(not source.active, 'duplicate notification source registration')
    source.active, source.spec = true, spec
    local released = false
    return function()
      if released then return end
      released = true
      source.releases = source.releases + 1
      source.active = false
    end
  end,
}

-- Late loading is discovered from package.loaded; attach never requires modules.
package.loaded['which-key'] = nil
package.loaded['which-key.config'] = nil
adapter.attach(ctx)
equal(package.loaded['which-key'], nil, 'attach forced which-key to load')
equal(package.loaded['which-key.config'], nil, 'attach forced which-key.config to load')
equal(adapter.info(ctx).reason, 'not_loaded', 'missing module reason')
adapter.attach(ctx)
equal(source.registrations, 1, 'repeated attach duplicated notification source')
adapter.detach()
adapter.detach()
equal(source.releases, 1, 'detach/release are not idempotent')
check(not source.active, 'notification source survived detach')

local user_calls, setup_calls = 0, 0
local function user_formatter(value)
  user_calls = user_calls + 1
  return value == 'user-source' and 'Delete' or value
end
local config = { replace = { key = {}, desc = { user_formatter, { '^%+', '' } } } }
local wk = {}
local original_setup = function(action)
  setup_calls = setup_calls + 1
  if action == 'error' then error('original-which-key-setup') end
  config.replace.desc = { user_formatter, { '^%+', '' } }
  return 'setup-result', nil, 'third-return'
end
wk.setup = original_setup
package.loaded['which-key'] = wk
package.loaded['which-key.config'] = config
local view = {}
function view.replace(field, value)
  for _, replacement in pairs(config.replace[field]) do
    value = type(replacement) == 'function' and (replacement(value) or value)
      or value:gsub(replacement[1], replacement[2])
  end
  return value
end

adapter.attach(ctx)
local wrapped_setup = wk.setup
local original_desc_count = 2
equal(#config.replace.desc, original_desc_count + 1, 'desc formatter not installed')
check(wrapped_setup ~= original_setup, 'public setup was not chained')
local info = adapter.info(ctx)
check(info.active and info.seam == 'replace.desc', 'active capability missing')
check(info.provenance:find('no mapping provenance', 1, true), 'replace.desc collision limitation missing')

local rhs = function() return 'executed' end
local mapping = { lhs = '<leader>d', rhs = rhs, desc = 'Delete', buffer = 7 }
equal(view.replace('desc', mapping.desc), '删除', 'default description translation')
equal(view.replace('desc', 'user-source'), '删除', 'user formatter chaining')
equal(view.replace('desc', '+Delete'), '删除', 'pattern formatter ordering')
equal(view.replace('desc', 'Unknown mapping'), 'Unknown mapping', 'unknown mapping fallback')
equal(view.replace('desc', 'window'), 'Window', 'window terminology changed')
equal(view.replace('desc', 'registers'), 'Register', 'registers terminology changed')
equal(view.replace('desc', 'Last change in current buffer'), '当前Buffer最后修改', 'buffer terminology changed')
equal(view.replace('desc', 'alternate buffer'), '备用Buffer', 'alternate buffer terminology changed')
equal(view.replace('key', mapping.lhs), mapping.lhs, 'key changed')
check(mapping.lhs == '<leader>d' and mapping.rhs == rhs and mapping.desc == 'Delete' and mapping.buffer == 7,
  'mapping identity/rhs/desc/buffer was mutated')

local registrations_before = source.registrations
adapter.attach(ctx)
equal(#config.replace.desc, original_desc_count + 1, 'repeated attach duplicated desc formatter')
check(wk.setup == wrapped_setup, 'repeated attach stacked setup wrapper')
equal(source.registrations, registrations_before, 'repeated setup registered source twice')

local ok, err = pcall(wk.setup, 'error')
check(not ok and tostring(err):find('original-which-key-setup', 1, true), 'original setup error was swallowed')
local returns = pack(wk.setup('rebuild'))
equal(returns.n, 3, 'setup return arity changed')
equal(returns[1], 'setup-result', 'setup first return changed')
equal(returns[2], nil, 'setup nil return changed')
equal(returns[3], 'third-return', 'setup third return changed')
equal(#config.replace.desc, original_desc_count + 1, 'public setup did not reattach exactly once')
equal(view.replace('desc', 'Next word'), '下一个词', 'translation after setup rebuild')

translation_error = true
equal(view.replace('desc', 'Delete'), 'Delete', 'translation exception did not fall back')
translation_error = false
enabled = false
equal(view.replace('desc', 'Delete'), 'Delete', 'dynamic disable still translated')
enabled = true

-- Direct list/function replacement is owned by the caller and is never reclaimed.
local old_list = config.replace.desc
local old_formatter = old_list[#old_list]
local external_list = { function(value) return 'External ' .. value end }
config.replace.desc = external_list
adapter.attach(ctx)
equal(#external_list, 1, 'external replacement list was reclaimed')
equal(adapter.info(ctx).reason, 'external_override', 'external list override not reported')
wk.setup('normal-setup-after-external-list')
equal(#config.replace.desc, original_desc_count + 1, 'normal setup did not reattach after external list')
equal(view.replace('desc', 'Delete'), '删除', 'normal setup exception did not resume translation')

old_list = config.replace.desc
old_formatter = old_list[#old_list]
external_list = { function(value) return 'External ' .. value end }
config.replace.desc = external_list
adapter.attach(ctx)
equal(adapter.info(ctx).reason, 'external_override', 'second external list override not reported')
local external_setup = function() return 'external-setup' end
wk.setup = external_setup
adapter.attach(ctx)
check(wk.setup == external_setup, 'external setup function was reclaimed')
equal(adapter.info(ctx).reason, 'external_override', 'external setup override not reported')
adapter.detach()
adapter.attach(ctx)
check(wk.setup == external_setup, 'detach/reattach reclaimed external setup')
equal(#external_list, 1, 'detach/reattach reclaimed external desc list')
equal(adapter.info(ctx).reason, 'external_override', 'external override was forgotten after reattach')
equal(old_formatter('Delete'), 'Delete', 'stale formatter reactivated after reattach')

-- Replacing both module tables cleans only our old artifacts and attaches the
-- new generation, without modifying either external replacement.
local new_config = { replace = { key = {}, desc = { user_formatter } } }
local new_wk = { setup = function() return 'new-setup' end }
local new_original_setup = new_wk.setup
package.loaded['which-key'] = new_wk
package.loaded['which-key.config'] = new_config
adapter.attach(ctx)
check(wk.setup == external_setup, 'old external setup was overwritten during generation change')
equal(#external_list, 1, 'old external list changed during generation change')
local found_old = false
for _, formatter in ipairs(old_list) do found_old = found_old or formatter == old_formatter end
check(not found_old, 'owned formatter was not removed from old module generation')
check(new_wk.setup ~= new_original_setup, 'new setup generation was not attached')
equal(#new_config.replace.desc, 2, 'new config generation was not attached')
config = new_config
equal(view.replace('desc', 'Delete'), '删除', 'new module generation translation')

local retained_formatter = new_config.replace.desc[#new_config.replace.desc]
adapter.detach()
adapter.detach()
check(new_wk.setup == new_original_setup, 'detach did not restore new setup generation')
equal(#new_config.replace.desc, 1, 'detach did not remove only the new owned formatter')
equal(retained_formatter('Delete'), 'Delete', 'retained stale formatter remained active after detach')
equal(source.releases, 3, 'lifecycle did not release each owned source exactly once')
check(source.spec.title == 'which-key.nvim' and source.spec.domain == 'which-key'
  and source.spec.context == 'notification', 'notification source route changed')
print('WHICH_KEY_ADAPTER_SPEC=PASS ownership generation idempotent fallback error_propagation')
