local M = {}

function M.get()
  local session = require('nvim-zh.session').snapshot()
  return {
    schema = 1,
    configured = session.configured,
    config = session.config,
    help = require('nvim-zh.help').info(session.config.modules.help),
    native = require('nvim-zh.native').info(),
    ui = require('nvim-zh.ui').info(),
    plugins = require('nvim-zh.plugins').info(),
    diagnostics = require('nvim-zh.diagnostics').info(),
    lsp = require('nvim-zh.lsp').info(),
    v_lang = vim.v.lang,
    helplang = vim.o.helplang,
    nvim_version = tostring(vim.version()),
    version = require('nvim-zh.resources').info(),
    runtime = require('nvim-zh.runtime').info(),
  }
end

return M
