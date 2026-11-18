# nvim-zh

面向 Neovim 的简体中文本地化插件。它把核心 gettext 消息、中文 Help、常见 Lua UI、受支持第三方插件以及 clangd 诊断/LSP 的**显示文本**接入同一套精确翻译与资源同步机制。

插件不扫描或改写编辑 Buffer，不修改原始诊断/LSP 协议对象、第三方源文件或外部工具输出；没有可靠译文的文本自然保留英文。

## 要求

- Neovim **0.12+**，使用内置 `vim.pack` 安装和更新。
- 中文 Help 和 Lua UI 适配不需要 Python、gettext 命令行工具或构建步骤。
- 自动绑定核心 MO 当前要求 **Linux/glibc + LuaJIT**；其他环境会明确报告原生部分不支持或降级，Help/UI 仍可使用。
- 翻译与固定上游基线为 Neovim **0.12.6**。支持边界和未验证项见[兼容性说明](docs/compatibility.md)。

项目仍处于开发期，当前版本为 `0.1.0-dev`。

## 安装

```lua
vim.pack.add({ 'https://github.com/DerckHanna/nvim-zh' }, { load = true })
require('nvim-zh').setup()
```

这就是最短可用配置。MO、中文 Help、帮助索引和翻译目录均随包交付；首次 setup 会校验并启用资源，不需要手动编译 MO、生成 helptags 或执行 Reload。

## 日常使用

- `:NvimZh`：打开只读中文面板，查看版本、翻译资源、缺失记录和健康状态。
- `:NvimZhCheck`：显示只读检查；也可使用 `:checkhealth nvim-zh`。
- 面板中 `Tab` / `Shift-Tab` 切页，`j` / `k` 滚动，`/` 搜索，`?` 打开 Help，`q` / `Esc` 关闭。

面板不下载更新、不编辑配置、不提供另一套回退命令。headless 环境可使用[结构化 Lua 接口](docs/api.md)。

### 更新

```lua
vim.pack.update()
```

在 vim.pack 的标准确认界面用 `:write` 接受；取消确认不会应用候选资源。确认后，插件自动同步同一安装修订中的 MO、Help、索引和翻译目录：

- 纯资源更新直接用于后续查询，不需要重启或手动 Reload。
- 实现代码变化会明确提示重启，下次启动自动完成同步。
- 损坏或不兼容的候选资源不会替换上一份已验证资源。
- 版本回退同样通过 vim.pack 与锁文件完成，资源跟随选中的安装修订。

### 少量常用配置

默认配置通常足够。以下示例仅演示可选项，不是安装所必需：

```lua
require('nvim-zh').setup({
  modules = {
    ui = { select_items = true },
    plugins = { disabled = { 'telescope' } },
  },
  overrides = {
    ['my-plugin'] = { [''] = { Save = '保存' } },
  },
})
```

需要持久热配置时，可创建 `stdpath('config')/nvim-zh.json`。保存后自动校验并应用；无效文件保留上一份有效配置，包更新不会覆盖该文件或其中的覆盖数据。

完整默认值、模块开关、JSON 格式和优先级见[配置文档](docs/configuration.md)。

## 覆盖范围

| 范围 | 行为 |
|---|---|
| 核心消息 | 继续使用 Neovim gettext，绑定用户数据目录中的已验证合并 MO，不替换系统 MO |
| 中文 Help | 通过 `.cnx` 与预生成 `tags-cn` 选择中文，缺失主题回退英文 |
| Neovim UI | 支持 notify、input/select；select item 格式化与 echo 为可选功能 |
| 第三方插件 | 围绕固定上游的公开接缝适配 which-key、Telescope、nvim-tree；其他私有 UI 不做猜测性接管 |
| 诊断与 LSP | 只翻译明确拥有的 clang/clangd 显示字段，原始数据、动作和取消语义不变 |
| 状态与排错 | 面板、健康检查、结构化状态、实际观察与脱敏缺失记录 |

具体接缝、固定 commit 和限制见[第三方插件适配](docs/adapters.md)。Help 与 native 的机器清单位于 `manifests/`；清单状态、结构校验和实际运行时观察是不同概念，均不代表“全部汉化”。

已知限制：

- 已显示的历史通知、旧 Help Buffer 和第三方私有视图不会被强制改写；后续自然刷新使用新资源。
- 未接入的插件、私有 UI、未知服务器和未知文本保留英文。
- 某些平台缺少原生 locale 能力时，只有核心原生消息降级，不会据此宣称全部中文可用。
- 固定 fixture 的命中数不是整个插件或 clangd 的汉化率。

## Lua 接口摘要

```lua
local zh = require('nvim-zh')

local snapshot = zh.status()       -- 配置、版本、资源和模块状态
local stats = zh.stats()          -- 已加载目录与本进程实际观察
local missing = zh.missing()      -- 脱敏缺失记录
local task_id = zh.refresh(function(result)
  vim.notify(vim.inspect(result)) -- 只重新协调本地配置和已安装资源，不下载
end)
```

`translate()`、`register_catalog()`、`open()`、`check()` 和 `teardown()` 的参数、返回值及错误契约见[Lua API](docs/api.md)。

## 文档与帮助

- 插件内 Help：`:help nvim-zh`
- [完整配置](docs/configuration.md)
- [Lua API](docs/api.md)
- [第三方插件适配](docs/adapters.md)
- [架构说明](docs/architecture.md)
- [兼容性与验证边界](docs/compatibility.md)
- [测试与质量门禁](docs/testing.md)
- [贡献指南](CONTRIBUTING.md)
- [变更记录](CHANGELOG.md)

遇到问题时，先查看 `:NvimZh` 的“检查”页或执行 `:checkhealth nvim-zh`，再附上面板中的运行版本、资源状态和具体降级原因。
