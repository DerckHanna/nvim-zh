from adapter_tui import assert_lua, run

SETUP = """
vim.cmd('runtime plugin/nvim-zh.lua')
vim.cmd('runtime plugin/cmp.lua')
local cmp = require('cmp')
local input = { label = 'alpha', kind = 3, labelDetails = { description = '[source text]' } }
cmp.register_source('fixture_ready', {
  complete = function(_, _, callback) callback({ input }) end,
})
cmp.register_source('fixture_unavailable', {
  is_available = function() return false end,
  complete = function() error('unavailable source invoked') end,
})
cmp.register_source('fixture_unused', { complete = function() error('unused source invoked') end })
function CmpTestSetup(entries, format)
  cmp.setup({
    sources = { { name = 'fixture_ready' }, { name = 'fixture_unavailable' }, { name = 'fixture_unknown' } },
    view = { entries = entries },
    formatting = { fields = { 'abbr', 'kind', 'menu' }, format = format },
    mapping = { ['<CR>'] = cmp.mapping.confirm({ select = true }) },
  })
end
CmpTestSetup('custom')
vim.keymap.set('i', '<F6>', function() cmp.complete() end)
function CmpBehavior()
  local item = {
    label = 'fixture_first', filterText = 'f', sortText = '01', kind = 3, insertTextFormat = 2,
    textEdit = { range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 1 } },
      newText = 'call(${1:value})' },
    additionalTextEdits = {
      { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } },
        newText = 'fixture include\\n' },
    },
    data = { origin = 'fixture' },
  }
  CmpBehaviorResult = {}
  cmp.register_source('fixture_behavior', {
    complete = function(_, _, callback)
      callback({ { label = 'fixture_second', filterText = 'f', sortText = '02', kind = 6 },
        { label = 'invisible', filterText = 'ZZ', sortText = '00' }, item })
    end,
    resolve = function(_, raw, callback)
      if raw.label == 'fixture_first' then CmpBehaviorResult.resolve = vim.deepcopy(raw) end
      callback(vim.tbl_extend('force', raw, { documentation = 'fixture raw documentation' }))
    end,
  })
  cmp.event:on('confirm_done', function(event)
    CmpBehaviorResult.candidate = vim.deepcopy(event.entry.completion_item)
  end)
  cmp.setup({
    sources = { { name = 'fixture_behavior' } }, completion = { autocomplete = false },
    sorting = { comparators = { cmp.config.compare.sort_text } },
    snippet = { expand = function(args)
      CmpBehaviorResult.snippet = args.body
      vim.snippet.expand(args.body)
    end },
  })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'anchor', '' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end
"""


def status(ui, enabled):
    headings = ('就绪的补全源', '不可用的补全源', '未启用的补全源', '未知的补全源') if enabled else (
        'ready source names', 'unavailable source names', 'unused source names', 'unknown source names')
    ui.command('CmpStatus')
    ui.expect(*headings, 'fixture_ready', 'fixture_unavailable', 'fixture_unused', 'fixture_unknown')
    ui.send('\r')
    ui.command("lua require('cmp').status()")
    ui.expect(*headings)


def deprecation(ui, enabled):
    ui.command("lua require('cmp').setup({ sources = { {name='fixture_ready', opts={fixture=4}} } })")
    ui.expect('已弃用' if enabled else 'is deprecated', 'sources[number].opts', 'sources[number].option')
    ui.send('\r')
    assert_lua(ui, "require('cmp').get_config().sources[1].option.fixture == 4", 'CMP_OPTION_PRESERVED')
    ui.command("lua require('cmp').setup({ documentation = {} })")
    ui.expect('已弃用' if enabled else 'is deprecated', 'window.documentation')
    ui.send('\r')
    ui.command("lua require('cmp.config').global.documentation = nil")
    ui.command("lua require('cmp').setup({ experimental = { native_menu = true } })")
    ui.expect('已弃用' if enabled else 'is deprecated', 'experimental.native_menu', 'view.entries')


def complete(ui, category):
    ui.send('ia')
    ui.send(b'\x1b[17~')
    ui.expect('alpha', category, '[source text]')


def accept(ui, category, marker):
    ui.send(b'\r')
    ui.expect(reject=(category, '[source text]'))
    ui.send(b'\x1b')
    ui.expect(reject=('-- INSERT --',))
    assert_lua(ui, "vim.api.nvim_get_current_line() == 'alpha'", marker)


def custom(ui, enabled):
    category = '函数' if enabled else 'Function'
    complete(ui, category)
    if enabled:
        assert ui.screen.widths(category) == [2, 2]
    accept(ui, category, 'CMP_INSERT_PRESERVED')
    ui.command('enew!')
    ui.resize(19, 54)
    ui.command("""lua CmpTestSetup('custom', function(_, item) item.kind = '自定义'; return item end)""")
    complete(ui, '自定义')
    accept(ui, '自定义', 'CMP_CUSTOM_INSERT_PRESERVED')
    if enabled:
        ui.command("NvimZhPacks disable nvim-cmp")
        ui.command('enew!')
        ui.command("lua CmpTestSetup('custom', function(_, item) return item end)")
        complete(ui, 'Function')


def native(ui, enabled):
    ui.command("lua CmpTestSetup('native')")
    complete(ui, 'Function')
    accept(ui, 'Function', 'CMP_NATIVE_INSERT_PRESERVED')


def lspkind(ui, enabled):
    ui.command("lua CmpTestSetup('custom', require('lspkind').cmp_format({mode='text'}))")
    complete(ui, 'Function')
    accept(ui, 'Function', 'LSPKIND_INSERT_PRESERVED')


def behavior(ui, enabled):
    ui.command('lua CmpBehavior()')
    ui.send('if')
    ui.send(b'\x1b[17~')
    category = '函数' if enabled else 'Function'
    frame = ui.expect('fixture_first', 'fixture_second', category, reject=('invisible',))
    assert frame.index('fixture_first') < frame.index('fixture_second')
    ui.send(b'\r')
    ui.expect('fixture include', 'call(value)', reject=(category,))
    ui.send(b'\x1b')
    ui.expect(reject=('-- INSERT --', 'SELECT'))
    assert_lua(
        ui,
        "CmpBehaviorResult.resolve.data.origin == 'fixture' and "
        "CmpBehaviorResult.candidate.label == 'fixture_first' and "
        "CmpBehaviorResult.candidate.filterText == 'f' and "
        "CmpBehaviorResult.candidate.kind == 3 and "
        "CmpBehaviorResult.candidate.documentation == 'fixture raw documentation' and "
        "CmpBehaviorResult.snippet == 'call(${1:value})'",
        'CMP_PROTOCOL_AND_EDITS_PRESERVED',
    )


def help_topic(ui, enabled):
    ui.command(
        'lua local root = vim.fn.tempname(); vim.fn.mkdir(root .. "/doc", "p"); '
        'assert(vim.uv.fs_copyfile(vim.env.NVIM_ZH_TEST_NVIM_CMP .. "/doc/cmp.txt", root .. "/doc/cmp.txt")); '
        'vim.cmd.helptags(root .. "/doc"); vim.opt.rtp:append(root)'
    )
    ui.command('help cmp-abstract')
    ui.expect('本文档介绍 nvim-cmp。' if enabled else "This is nvim-cmp's document.", '../lua/cmp/types/init.lua')


run('nvim-cmp', {'status': status, 'deprecation': deprecation, 'custom': custom, 'behavior': behavior,
                 'native': native, 'lspkind': lspkind, 'help': help_topic},
    dependencies=('NVIM_ZH_TEST_LSPKIND', 'NVIM_ZH_TEST_NVIM_CMP'), verify=True, setup=SETUP)
