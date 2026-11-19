# 验证记录

## 全量复审（2026-11-19）

本轮使用 Linux x86_64 / glibc、Neovim 0.12.6 和 `manifests/adapters/` 中的固定版本。在独立 Neovim 进程中验证启动、动态加载、配置回滚、翻译查找、英文回退、Help 和资源更新。固定上游矩阵有 60 个记录，其中 53 个终端场景共运行 104 次。表中的条目是目录规模，Help 数是已发布的主题摘译数。

| 插件 | 目录与 Help | 实际验证 | 英文来源与影响 |
| --- | --- | --- | --- |
| which-key `3aab2147` | 217 条，3 篇 | 打开内置映射、切换分组、缩窄终端查看滚动提示、查看 marks/Register、触发通知、运行健康报告和跳转 Help | 自定义描述、标记路径、Register 值和拼写候选来自用户或 Neovim。`replace.desc` 接收单个字符串，用户描述与内置条目撞字时可显示相同译文。 |
| Telescope `1e1bab73` | 164 条，3 篇 | 首次搜索、输入查询并打开文件、实时 Grep 精炼、映射浮窗、Git 分支创建/删除/合并/变基的提示、操作输出、通知、健康报告、Help、vim.pack 取消/更新/回退 | `builtin/__internal.lua` 中的 `Untitled` 同时是搜索条目数据。布局和参数校验中的直接 Lua 错误仍由 Neovim 以 E5108 等形式显示。第三方扩展的文本归扩展维护。 |
| nvim-tree `dbc9d96a` | 172 条，4 篇 | 打开目录树、查看默认映射、文件操作的确认框和回调、切换帮助排序与对齐、Window 选择、文件信息、简要和详细隐藏统计、Help、真实 lazy.nvim 晚加载 | `lua/nvim-tree/commands.lua` 中加载时登记的 12 条命令描述留在命令元数据中。`:NvimTreeHiTest` 使用私有诊断表头。路径、文件名和自定义映射描述来自本地数据。 |
| nvim-dap `cfa2d58f` | 161 条，4 篇 | REPL 帮助与无会话分支、选择器、输入值、Widget、异常诊断前缀、quickfix、线程、启动和解析错误、通知、健康报告、Help。通过 GDB 启动、命中条件断点、单步和继续至退出。 | `plugin/dap.lua` 中的 DapNew/DapEval 命令描述属于加载时命令元数据。`lua/dap/ext/vscode.lua:22` 的缺省 `Input` 与用户写下的同名描述共用显示值。DAP 服务端返回的值、栈和错误详情沿用服务端原文。 |
| nvim-dap-ui `cc9dd33a` | 41 条，3 篇 | 打开和关闭布局、缩窄终端、打开元素浮窗、选择 Window、查看映射和长值、触发无会话提示、跳转 Help。真实 GDB 调试中查看条件断点标签和变量值从 7 变为 8。 | `DAP Scopes` 等内部 Buffer 名用于查找。GDB 返回的 `Locals`、`Registers`、类型名和值属于协议数据。依赖和布局配置抛出的 Lua 错误沿用上游。 |
| lazy.nvim `306a0552` | 生命周期桥接 | 实测真实 lazy.nvim 完成 nvim-tree setup 后发出 `User LazyLoad` 并挂载适配。启停 nvim-zh 两组均打开 `:Lazy` 主面板。 | 主面板中的 `Install (I)`、`Update (U)`、`Help (?)` 来自 lazy.nvim 自有视图。安装进度、通知和帮助沿用上游。 |
| nvim-cmp `2ffe79f1` | 清单记录，补全数据保持原样 | 实测触发补全、查看条目和接受插入。对照启停时的 `abbr`、`kind` 和自定义 `menu`。 | 标签来自补全条目、LSP kind 与用户 formatter。应用全局词表会改写这些来源字段。 |

继续使用官方固定修订。标准 `vim.pack` 按仓库地址和实际模块路径自动取证，镜像或其他管理器仍可显式登记源码。which-key 与 Telescope 可在同一健康报告中显示中文。nvim-tree 以显示列对齐 Help 表头，并保留高亮字节偏移。动态模板无法从显示结果恢复相邻参数时回退原文。版本相关接缝与 Help 检查分别验证实际模块代次和文档摘要。

移除 `modules.help.vimcdoc` 与固定值 `terminology`，升级时从 Lua 和 `nvim-zh.json` 删除这两个字段。移除运行时对 `vim.loop`、早期包事件和旧高亮 API 的兼容分支，使用 Neovim 0.12 的接口。发布候选排除工作环境创建的空元数据挂载目录，非空目录仍由发布检查拒绝。

| 检查 | 实际结果 |
| --- | --- |
| `make check-syntax check-translations check-native` | PASS，41 个 Python、10 个 Shell、112 个 Lua 文件通过语法检查。7 个目录共 777 条，核心 MO 通过校验。 |
| `tools/native_catalog.py audit` | PASS，118 条补译中找到 76 条裸键、25 条裸键和错误码前缀形式、2 条 runtime 来源。另有 15 条仍缺少运行时字面量证据。 |
| `make build-resources check-resources check-reproducible release-check` | PASS，重建 170 个资源文件，Lua 目录、MO 和完整资源均可逐字节复现，发布候选 543 个文件。 |
| `make test`，启用真实原生检查与本机 clangd | PASS，60 个 Lua 规格、116 个 Python 用例、133 篇核心 Help 结构校验、真实中文 MO 消息和欢迎页、PTY、配置回滚及并发资源快照。 |
| `make test-upstream` 与额外 Help 探针 | PASS，全部固定上游记录。真实 `:help` 打开五个适配器的 67 个中文标签，其中 50 个上游同名标签还验证了 `@en`。 |
| GDB 18.1 的 DAP 终端探针 | PASS，中文启用/关闭均完成实际调试。默认沙箱禁止 ptrace，经授权在沙箱外运行探针。 |
| `make sync`、`bash benchmarks/run.sh`、`git diff --check` | PASS，离线同步无变更，202 个 UI 事件保留 history 和 cmdheight，当前差异无空白错误。 |

本机 clangd 23.1.5 的真实 push 验证了六条诊断以及 quickfix 和 LSP 原始数据，服务器对 diagnostics pull 返回 `-32601`。成功 pull 路径由独立契约覆盖。133 篇核心 Help 检查标签、示例块和链接结构。第三方其余帮助主题按 Neovim 语言顺序回退。Windows、macOS、musl、nightly、其他上游修订与其他外部调试器未参与本次运行。

## 历史资料

- [2026-11-18 验证记录与后续补测](archive/verification-2026-11-18.md)
- [2026-11-18 质量审计](archive/quality-audit-2026-11-18.md)
