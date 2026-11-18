local M = {}
local state = { configured = false, config = require('nvim-zh.config').resolve() }

function M.prepare(opts)
  local config = require('nvim-zh.config').resolve(opts)
  require('nvim-zh.catalog').register_builtins()
  return config
end

function M.apply(config)
  require('nvim-zh.engine').setup(config)
  require('nvim-zh.help').setup(config.modules.help)
  require('nvim-zh.ui').setup(config.modules.ui)
  require('nvim-zh.plugins').setup(config.modules.plugins)
  require('nvim-zh.diagnostics').setup(config.modules.diagnostics)
  require('nvim-zh.lsp').setup(config.modules.lsp)
  state = { configured = true, config = config }
  return M
end

function M.restore(config, configured)
  if configured then return M.apply(config) end
  for _, name in ipairs({ 'ui', 'plugins', 'diagnostics', 'lsp' }) do
    require('nvim-zh.' .. name).teardown()
  end
  require('nvim-zh.help').setup({ enabled = false })
  require('nvim-zh.engine').setup(config)
  state = { configured = false, config = config }
  return M
end

function M.snapshot()
  return { configured = state.configured, config = vim.deepcopy(state.config) }
end

function M.teardown()
  M.restore(state.config, false)
  require('nvim-zh.help').set_resource_root(nil)
end

return M
