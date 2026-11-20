# 配置

普通用户只需要：

```lua
require('nvim-zh').setup()
```

下面的选项均可省略。未提供的字段使用默认值；未知字段和错误类型会被拒绝，而不是静默忽略。

## 默认配置

```lua
require('nvim-zh').setup({
  modules = {
    core = { enabled = true, apply_language = true },
    help = { enabled = true, lang = { 'cn', 'en' } },
    ui = { notify = true, prompts = true, select_items = false, echo = false },
    plugins = { auto = true, lazy_load = true, disabled = {} },
    diagnostics = {
      enabled = true,
      virtual_text = true,
      virtual_lines = true,
      float = true,
      lists = true,
    },
    lsp = { messages = true, progress = true, hints = true },
  },
  pack_sources = {},
  overrides = {},
  missing = { enabled = true, max_entries = 2000 },
})
```

## 模块开关

### `modules.core`

控制 Neovim 原生 gettext 消息的自动接线，不影响中文 Help 或 Lua UI 适配。

- `enabled = false`：关闭原生消息模块。
- `apply_language = false`：保留模块配置，但不自动绑定 MO、切换消息语言或准备私有 locale。

受支持的环境中，插件把 `nvim` gettext domain 绑定到用户数据目录里的已验证 MO 快照。系统 Neovim、系统 MO、子进程环境和其他 locale 分类不被替换。缺少平台能力时，原生部分报告降级，Help/UI 继续使用。

### `modules.help`

- `enabled`：是否把中文 Help 加入 `'helplang'` 选择。
- `lang`：按优先级排列的语言列表，默认 `{ 'cn', 'en' }`；数组整体替换。

重复设置或关闭模块时，只移除本插件拥有语言项，保留用户后来添加的其他语言。缺少中文 tag 的主题由 Neovim 自然回退英文。

### `modules.ui`

- `notify`：适配 `vim.notify` 的消息；`vim.notify_once` 仍按英文原文去重。
- `prompts`：适配 `vim.ui.input` / `vim.ui.select` 的 `prompt` 和 `title`。
- `select_items`：在 `prompts` 已启用时，包装公开的 `opts.format_item` 以适配选择项显示文本；默认关闭。原始 item、索引和回调返回值不变。
- `echo`：适配 `vim.api.nvim_echo` 的文本 chunk；默认关闭。高亮、history、opts 和消息元数据不变，fast event 直接回退原实现。

这些接缝只处理精确目录中的显示文本，不扫描 Buffer，不替换终端字节流。

### `modules.plugins`

- `auto`：自动适配已经加载且公共接口兼容的受支持插件，不为了汉化强制 `require` 插件。
- `lazy_load`：通过 `User LazyLoad` 和后续 Buffer/焦点边界处理晚加载模块。
- `disabled`：要关闭的适配器名称数组，例如 `{ 'telescope', 'nvim-tree', 'nvim-dap', 'nvim-dap-ui' }`。

支持的接缝、固定上游和限制见[第三方插件适配](adapters.md)。外部插件后来替换同一函数时，本插件不抢回所有权，并在状态中报告 `external_override`。

### `modules.diagnostics`

诊断译文由 clangd 汉化包提供，可通过 `:NvimZhPacks` 安装。

`enabled` 是总开关。`virtual_text`、`virtual_lines` 和 `float` 分别控制行尾、虚拟行和浮窗。Neovim 已启用的诊断显示会使用中文译文。浮窗也会翻译已收录的相关位置说明。

`lists` 控制 `vim.diagnostic.setqflist()` 和 `vim.diagnostic.setloclist()` 生成的诊断列表。插件先调用用户 formatter，再翻译显示文字。用户 formatter 返回 `nil` 时仍隐藏对应诊断，其异常继续传播。`vim.diagnostic.get()` 仍返回完整原文，可用诊断代码和 `user_data.lsp` 查找上游说明。

### `modules.lsp`

- `messages`：适配 clangd 的 `window/showMessage` 和 `window/showMessageRequest` 显示字段。
- `progress` 启用工作进度译文，并适配通过 `vim.lsp.handlers` 注册的 `textDocument/clangd.fileStatus`。
- `hints` 启用悬浮说明、重载签名标题、原生补全的头文件与重载说明，以及代码操作标题。代码操作菜单使用 `modules.ui.prompts` 的选择器适配。

原生补全保留标识符、插入文本和编辑范围。语言服务器协议记录及 `window/logMessage` 仍使用英文。当前词库离线运行，遇到目录未收录的诊断和提示时显示原文。

声明兼容范围的工具包使用 clangd 的 `serverInfo` 和当前协议方法选择显示词条。
例如，0.1.1 词库验证了 clangd 23.1.5 x86_64 Linux 的 push、代码操作、悬浮、
补全、签名和进度。缺少版本或接口证据时，相应显示保留原文，C/C++ 状态说明原因。
显式用户覆盖仍可在没有词库包的会话使用。

可按诊断代码添加或覆盖译文。通用诊断使用 `diagnostic` context。`{name}` 会保留诊断中的变量名，例如 `unused`。

```lua
require('nvim-zh').setup({
  overrides = {
    clangd = {
      ['-Wunused-variable'] = {
        ["Unused variable '{name}'"] = "未使用的变量 '{name}'",
      },
    },
  },
})
```

## 汉化包发布源

在 `:NvimZh` 的「汉化包」页管理已安装的包。官方源随主包登记。可在 Lua
`setup()` 中通过 `pack_sources` 添加自定义 HTTPS 索引。带 Lua 入口的自定义
包需要该来源配置 `allow_lua = true`。

```lua
require('nvim-zh').setup({
  pack_sources = {
    community = { url = 'https://example.org/nvim-zh/catalog.json' },
  },
})
```

遇到重名包时，可用 `:NvimZhPacks install community:包ID` 指定来源。
安装状态和暂停开关按用户数据目录保存。`modules.plugins` 继续控制插件显示
接缝，`modules.diagnostics` 和 `modules.lsp` 控制对应工具界面。

## 翻译覆盖

`overrides` 是纯数据，按 domain、显式 context、原始 msgid 索引。空 context 使用 `''`：

```lua
require('nvim-zh').setup({
  overrides = {
    ['my-plugin'] = {
      [''] = { Save = '保存' },
      menu = { Open = '展开' },
    },
  },
})
```

覆盖在内置目录之后合并。函数、loader 和可执行规则不属于覆盖数据。动态模板只支持经过校验的 `{name}` 或 printf 占位符；未命中或有歧义时回退原文。命令、代码、路径、快捷键和用户数据不会因全局术语替换而被改写。

维护端术语表约束编辑源。升级时请从 Lua 和 `nvim-zh.json` 删除 `terminology` 与 `modules.help.vimcdoc`。

## 缺失记录

```lua
missing = { enabled = true, max_entries = 2000 }
```

记录仅保存在当前进程，默认不上传、不写持久日志。`max_entries` 是正整数，分别限制已译与缺失的去重缓存，超出时淘汰最久未使用的记录。动态文本、路径和超长原文以 SHA-256 摘要标签代替。统计只表示已接入入口的实际观察，不是整个 Neovim 或某个第三方插件的汉化率。

## 可选 JSON 热配置

默认不需要配置文件。需要持久覆盖 `setup(opts)` 时，编辑：

```lua
vim.cmd.edit(vim.fn.stdpath('config') .. '/nvim-zh.json')
```

示例：

```json
{
  "schema": 1,
  "modules": {
    "ui": { "notify": false },
    "plugins": { "disabled": ["telescope"] }
  },
  "overrides": {
    "my-plugin": { "": { "Save": "保存" } }
  }
}
```

规则如下：

1. 优先级为默认值 `<` `setup(opts)` `<` 本地 JSON。
2. 普通对象递归合并；`help.lang` 和 `plugins.disabled` 数组整体替换。
3. 保存文件后自动校验并应用；外部修改在恢复焦点或进入 Buffer 时补检。
4. 删除字段会继承低层配置；删除整个文件恢复 `setup(opts)` 与默认值。
5. JSON 无效、包含未知字段或应用失败时，保留上一份有效配置，并在面板中显示错误。
6. 任意 `init.lua`、第三方 Lua 文件和插件实现更新都不会被当作热配置自动执行；实现更新按提示重启。

此文件位于用户配置目录，不属于插件包。vim.pack 更新不会覆盖它，也不会覆盖其中的翻译覆盖数据。
