local M = {}

function M.setup(opts)
  local session = require('nvim-zh.session')
  local config = session.prepare(opts)
  require('nvim-zh.runtime').setup(config, session)
  return M
end

function M.status()
  return require('nvim-zh.status').get()
end

function M.translate(spec)
  return require('nvim-zh.engine').translate(spec)
end

function M.register_catalog(domain, loader, metadata)
  return require('nvim-zh.catalog').register(domain, loader, metadata)
end

function M.register_adapter_source(id, directory)
  return require('nvim-zh.plugins').register_source(id, directory)
end

function M.register_adapter(definition)
  return require('nvim-zh.plugins').register_adapter(definition)
end

function M.stats()
  return require('nvim-zh.engine').stats()
end

function M.missing()
  return require('nvim-zh.missing').list()
end

function M.open()
  return require('nvim-zh.tui').open()
end

function M.check(callback)
  return require('nvim-zh.health').run(callback)
end

function M.refresh(callback)
  return require('nvim-zh.runtime').refresh(callback)
end

function M.teardown()
  local tui = package.loaded['nvim-zh.tui']
  if tui then tui.close() end
  local health = package.loaded['nvim-zh.health']
  if health then health.stop() end
  local ok, err = require('nvim-zh.runtime').stop()
  local restored, why = pcall(require('nvim-zh.session').teardown)
  if not ok then return nil, err end
  if not restored then return nil, why end
  return true
end

return M
