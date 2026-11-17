local function check(value, message)
  if not value then error(message, 2) end
end
local function equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %q, got %q'):format(message, expected, actual), 2)
  end
end

local function setup(enabled)
  require('nvim-zh').setup({
    modules = {
      core = { enabled = false },
      help = { enabled = enabled, lang = { 'cn', 'en' } },
      ui = { notify = false, prompts = false, echo = false },
      plugins = { auto = false },
      diagnostics = { enabled = false },
      lsp = { messages = false, progress = false },
    },
  })
end

vim.o.helplang = 'de,de'
setup(false)
equal(vim.o.helplang, 'de,de', 'initially disabled help module normalized user options')

vim.o.helplang = 'de,it'
setup(true)
equal(vim.o.helplang, 'cn,de,it,en', 'initial help language merge')
setup(true)
equal(vim.o.helplang, 'cn,de,it,en', 'repeated help setup')
setup(false)
equal(vim.o.helplang, 'de,it', 'disabling help did not remove only plugin-owned languages')

vim.o.helplang = 'de,it'
setup(true)
vim.o.helplang = 'cn,de,fr,en'
setup(false)
equal(vim.o.helplang, 'de,fr', 'help teardown discarded an external language addition')

vim.o.helplang = 'cn,de'
setup(true)
equal(vim.o.helplang, 'cn,de,en', 'user-owned Chinese help language was duplicated')
setup(false)
equal(vim.o.helplang, 'cn,de', 'help teardown removed a user-owned language')

vim.o.helplang = 'de,en'
setup(true)
setup(false)
equal(vim.o.helplang, 'de,en', 'help teardown removed a user-owned English fallback')

print('HELP_OWNERSHIP_SPEC=PASS disable_restore=true external_additions=preserved')
