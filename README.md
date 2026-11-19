# nvim-zh

Neovim 简体中文本地化插件，覆盖核心消息、中文帮助、常见 UI、六个第三方插件的部分界面，以及 clangd 的部分诊断和 LSP 提示。命令、快捷键、用户输入和协议数据沿用原值。

## 要求

- Neovim **0.12+**，使用内置 `vim.pack` 安装和更新。
- 安装包自带帮助、翻译目录与 MO。自动启用核心消息需要 **Linux/glibc + LuaJIT**，中文帮助与 Lua UI 可独立使用。
- 当前开发版本为 `0.1.0-dev`，固定验证版本为 Neovim **0.12.6**。见[兼容性说明](docs/compatibility.md)。

## 安装

```lua
vim.pack.add({ 'https://github.com/DerckHanna/nvim-zh' }, { load = true })
require('nvim-zh').setup()
```

首次 `setup()` 会校验并启用随包资源。使用受支持的第三方插件时，把上面的配置放在目标插件加载之前。标准 `vim.pack` 按仓库地址识别固定接缝，镜像或其他管理器可显式登记源码。见[第三方插件适配](docs/adapters.md#启用版本相关接缝)。

## 日常使用

- 用 `:NvimZh` 查看版本、资源、缺失记录和健康状态。`Tab` 与 `Shift-Tab` 切页，`j` 与 `k` 滚动，`/` 搜索，`?` 打开帮助，`q` 或 `Esc` 关闭。
- 用 `:NvimZhCheck` 或 `:checkhealth nvim-zh` 查看检查结果。
- 用 `:help nvim-zh` 打开帮助，或用 `:help nvim-zh@en` 选择英文版本。

### 更新

```lua
vim.pack.update()
```

在 vim.pack 的确认界面用 `:write` 接受更新。插件随安装修订同步 MO、Help、索引和翻译目录。

- 纯资源更新用于后续查询。实现变化会提示重启，并在下一次启动时应用。
- 取消更新或资源校验失败时继续使用上一份已验证资源。包版本和回退由 vim.pack 的锁文件管理。

### 常用配置

按需启用选择项格式化、禁用单个适配器或覆盖译文。

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

需要持久热配置时，可创建 `stdpath('config')/nvim-zh.json`。保存后自动校验并应用。校验失败时保留上一份有效配置。

完整默认值、模块开关、JSON 格式和优先级见[配置文档](docs/configuration.md)。

## 覆盖范围

| 范围 | 行为 |
|---|---|
| 核心消息 | 继续使用 Neovim gettext，绑定用户数据目录中的已验证合并 MO，不替换系统 MO |
| 中文 Help | 通过 `.cnx` 与预生成 `tags-cn` 选择中文，缺失主题回退英文 |
| Neovim UI | 支持 notify、input/select；select item 格式化与 echo 为可选功能 |
| 第三方插件 | 围绕固定上游的公开或已验证显示接缝适配 which-key、Telescope、nvim-tree、nvim-dap、nvim-dap-ui、nvim-dap-view |
| 诊断与 LSP | 只翻译明确拥有的 clang/clangd 显示字段，原始数据、动作和取消语义不变 |
| 状态与排错 | 面板、健康检查、结构化状态、实际观察与脱敏缺失记录 |

缺少中文帮助主题或匹配译文时使用上游文字。后续打开的帮助及新通知使用当前资源。逐插件的实际验证与剩余英文来源见[验证记录](docs/verification.md)。

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

完整接口、回调和错误字段见[Lua API](docs/api.md)。

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
