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

function M.raw()
  return require('nvim-zh.compiler').raw()
end

function M.raw_text()
  return require('nvim-zh.compiler').raw_text()
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
  local cancelled = health and health.stop(true)
  local ok, err = require('nvim-zh.runtime').stop(require('nvim-zh.session').teardown)
  if cancelled then cancelled() end
  return ok, err
end

return M
