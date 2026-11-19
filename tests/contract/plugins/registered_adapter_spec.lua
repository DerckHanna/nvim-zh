local zh = require('nvim-zh')
local original = function() return 'Open', nil, 'fixture' end
local module = { title = original }
package.loaded['external-fixture'] = module
local opts = { modules = { core = { enabled = false } } }
zh.setup(opts)

local definition = {
  api = 1,
  id = 'external-fixture',
  domain = 'external-fixture',
  catalog = { schema = 1, domain = 'external-fixture', locale = 'zh_CN',
    entries = { { context = 'title', msgid = 'Open', msgstr = '打开' } } },
  surfaces = {
    title = {
      module = 'external-fixture',
      probe = function(target) return type(target.title) == 'function' and target end,
      mount = function(scope, target)
        return scope.wrap(target, 'title', function(previous)
          return function(...)
            local title, hole, payload = previous(...)
            return scope.translate('title', title), hole, payload
          end
        end)
      end,
    },
  },
}

local release = zh.register_adapter(definition)
assert(not pcall(zh.register_adapter, definition), 'duplicate registration accepted')
local owned = module.title
local text, hole, payload = owned()
assert(text == '打开' and hole == nil and payload == 'fixture', 'projection lost behavior')
assert(zh.status().adapters['external-fixture'].surfaces.title.active)
zh.setup(opts)
assert(module.title == owned, 'wrapper stacked on repeat')

local replacement = { title = original }
package.loaded['external-fixture'] = replacement
assert(owned() == 'Open', 'stale retained wrapper still translating')
zh.setup(opts)
assert(module.title == original and replacement.title() == '打开', 'generation did not switch')
local foreign = function() return 'foreign' end
replacement.title = foreign
zh.setup(opts)
assert(zh.status().adapters['external-fixture'].surfaces.title.status == 'external_override')
release()
release()
assert(replacement.title == foreign and not zh.status().adapters['external-fixture'])
assert(zh.translate({ domain = 'external-fixture', context = 'title', msgid = 'Open' }) == 'Open')

replacement.title = original
local broken = vim.deepcopy(definition)
broken.surfaces.title.mount = function(scope, target)
  scope.wrap(target, 'title', function() return function() return 'unexpected' end end)
  error('fixture mount failed')
end
assert(not pcall(zh.register_adapter, broken), 'failing adapter registered')
assert(replacement.title == original and not zh.status().adapters['external-fixture'], 'rollback leaked')
zh.register_adapter(definition)()
local named_like_status = vim.deepcopy(definition)
named_like_status.surfaces.active = named_like_status.surfaces.title
named_like_status.surfaces.title = nil
local release_active = zh.register_adapter(named_like_status)
assert(zh.status().adapters['external-fixture'].surfaces.active.active)
release_active()
assert(zh.teardown())
print('REGISTERED_ADAPTER_SPEC=PASS translation duplicate scope generation foreign ownership registration rollback')
