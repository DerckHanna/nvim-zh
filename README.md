# nvim-zh

Neovim 简体中文本地化插件。基础安装提供核心消息、中文帮助和常见界面译文。可选汉化包补充第三方插件和 Clang 工具链的界面。命令、快捷键、用户输入和协议数据沿用原值。

## 安装

需要 Neovim 0.12 或更高版本。项目以官方 0.12.6 验证固定源码接缝。自动切换核心 gettext 消息需要 Linux/glibc 与 LuaJIT，中文帮助和 Lua 界面可独立使用。见[兼容性](docs/compatibility.md)。

```lua
vim.pack.add({ 'https://github.com/DerckHanna/nvim-zh' }, { load = true })
require('nvim-zh').setup()
```

在目标插件加载前运行 `setup()`，以启用需要固定源码证据的适配。见[第三方插件](docs/adapters.md)。

## 使用和更新

| 命令 | 用途 |
| --- | --- |
| `:help nvim-zh` | 阅读中文帮助，追加 `@en` 查看英文 |
| `:NvimZh` | 查看当前资源、缺失记录和状态 |
| `:NvimZhPacks` | 管理可选汉化包，首次进入按回车获取目录 |
| `:NvimZhCheck` | 查看运行检查，也可执行 `:checkhealth nvim-zh` |
| `:NvimZhRaw` | 查看选中的诊断或编译器列表条目的原文 |

运行 `vim.pack.update()` 更新主包，在确认界面用 `:write` 接受变更。可选包在 `:NvimZhPacks` 中独立更新。面板会在插件实现变化时提示重启。在线安装需要 `curl`，离线可用面板的 `a` 菜单导入已下载的附件。

公开目录提供 SDK 2 格式。升级到 0.4.0 后，可在 `:NvimZhPacks` 中安装或更新可选包。见[发行说明](CHANGELOG.md)。

## 可选汉化包

- **插件** · which-key、Telescope、nvim-tree、nvim-cmp、nvim-dap、nvim-dap-ui、nvim-dap-view、snacks.nvim、blink.cmp、cmake-tools.nvim、aerial.nvim、gitsigns.nvim、conform.nvim、mini.nvim、nvim-treesitter。逐项适配范围见[插件指南](docs/adapters.md)。
- **C/C++** · clangd、Clang 和 clang-tidy。诊断、悬浮、签名、构建列表及若干其他显示依赖固定工具版本和来源证据。见 [C/C++ 工作流](docs/workflows.md)与[工具链覆盖](docs/toolchain-coverage.md)。

## 文档

- [配置](docs/configuration.md) · [Lua API](docs/api.md) · [常用工作流](docs/workflows.md)
- [兼容性](docs/compatibility.md) · [验证记录](docs/verification.md) · [变更记录](CHANGELOG.md)
- [贡献指南](CONTRIBUTING.md) · [测试](docs/testing.md) · [架构](docs/architecture.md)

报告问题时，请附上 Neovim 版本、复现步骤及 `:checkhealth nvim-zh` 中相关的状态和降级原因。
