# 验证记录

## 0.4.0 · 验收基线（2026-11-22）

主仓库对照基线为 `20bae89`（`v0.3.0`），包目录对照基线为 `7f09e53`。本轮在 Linux x86_64/glibc 使用官方 Neovim 0.12.6、隔离 XDG 与固定上游源码验证新增 8 个插件包及 `nvim-tree` 新 target。

| 检查 | 本地结果 |
| --- | --- |
| 基础资源、测试与发布打包 | PASS。`make build-resources check-syntax check-translations check-native check-adapters check-resources check-reproducible test release-check` 全部通过（`CATALOG_CHECK=PASS domains=19 entries=71041`，`RESOURCE_BUNDLE=PASS 142 files`，发布候选含 649 个文件），`make sync` 离线检查无漂移。 |
| 新增 8 插件 + `nvim-tree` 固定上游与 PTY TUI | PASS。`snacks`、`blink-cmp`、`cmake-tools`、`aerial`、`gitsigns`、`conform`、`mini`、`nvim-treesitter`、`nvim-tree` 全部通过 `adapter_tool.py test --upstream` 的 Lua 集成测试与 `enabled=false` / `enabled=true` PTY TUI 对比场景。 |
| 真实 Neovim 0.12 配置实机验证 | PASS。以 SDK 2 本地语言包加载 12 个已装插件（含 8 个新包与 `nvim-tree`），全部通过 SHA-256 证据校验并激活；抽查 Snacks dashboard/picker/health、`:ConformInfo`、`:AerialInfo`/`:AerialToggle`、`cmake-tools`、Gitsigns、`mini.statusline`、`nvim-treesitter`、`blink.cmp` health 与 `nvim-tree` 映射均正常且无新增报错。 |
| SDK 2 `0.4.0` 发行附件 | PASS。9 个 `0.4.0` 附件与合并后的 `catalog.json` 双次构建逐字节一致；既有 13 条 `0.2.0`/`0.3.0` 公开记录完整保留。 |

## 0.3.0 · 验收基线（2026-11-21）

主仓库对照基线为 `47ceec9`，包目录对照基线为 `8072cf8`。本轮在 Linux x86_64/glibc 使用摘要匹配的官方 Neovim 0.12.6（SHA-256 `2e150e924a93930295deff9ca3c02c8828590ce3d04ce7b3ef49c8804adde973`）、隔离 XDG、空 `LOCPATH` 与固定上游源码。本节保留发布前的本地验证与迁移对照。

| 检查 | 本地结果 |
| --- | --- |
| 基础资源、测试与发布打包 | PASS。`make check-syntax check-translations check-native check-resources check-reproducible test release-check` 通过，发布候选含 601 个文件。`make sync` 为 `changes=0 network=false`。启用真实 native runtime 与 `/usr/bin/clangd` 后集成与 E2E 均通过。系统临时 locale 探针在空 `LOCPATH` 且缺少可用 locale/MO 输入时记 SKIP。 |
| 列表、构建和 LSP 专项 | PASS。覆盖不同窗口与 Tab 的相对编译器、异步返回顺序、旧跟踪槽碰撞下的 quickfix/loclist 原文、`:NvimZhRaw` 和退出状态。混合 LSP namespace 在虚拟文本、虚拟行、float 和两个列表入口隔离。混合 hover、独立进度 token、detach 和 Unicode fileStatus URI 另有断言。 |
| 真实 DAP 及固定上游矩阵 | PASS。完整矩阵含原 67 条记录和新增 8 条，共 75 条。其中 67 条为真实 PTY 场景。双 CodeLLDB 分别显示同名变量 `counter = 101` 和 `counter = 202`，作用域标签按来源决定。另验证晚到 Scope 响应不能覆盖现有会话画面。 |
| nvim-cmp | PASS。状态、弃用提示、默认类别、自定义 formatter、真实 lspkind、原生菜单、排序筛选、snippet、附加编辑、resolve 和 Help 均走固定上游。Help 的 tag、链接与示例块做完整等价检查。 |
| SDK 2 发行附件 | PASS。十个 `0.3.0` 附件与目录双次构建逐字节一致。发行目录保留三个 SDK 2 `0.2.0` 版本。平台探针验证导入、损坏回退、离线回滚和登记原子性。 |
| Linux 平台和工作流 | PASS。`localization.lua` 与 `packs.lua` 本机通过。C++/DAP 与 Python/Git 的启停组在原始数据、编译或工具退出状态、跳转和实际结果上一致。 |
| Clang 工具链完整覆盖 | PASS。48 次驱动调用，602 个 clang-tidy 检查均有登记。`0.3.0` 的 SDK 2 Clang 三包通过真实 PTY 启停对照。本轮复算 91,654 个样本，缺译、歧义与证据缺口均为零，`TOOLCHAIN_COMPLETE=PASS`。 |

GitHub Actions 的结果可按发行 tag 查询。[测试](https://github.com/DerckHanna/nvim-zh/actions/workflows/test.yml) · [平台探针](https://github.com/DerckHanna/nvim-zh/actions/workflows/platform.yml)

## SDK 2 迁移对照

发行准备期以真实 SDK 1 旧附件和隔离发布源验证六个存量插件的导入、升级冻结、重启生效、损坏回退与零网络请求回滚。`v0.1.0` 客户端的 SDK 1 选版在隔离迁移目录中通过。

六包对照使用已发布 SDK 1 `0.1.0` 和同机的 SDK 2 迁移预构建。每包每种 SDK 用五个独立进程校验并加载快照，计时与 GC 后 Lua 堆增量取中位数。DAP 包的读数包含本轮实现变化。RSS 增量中位数在两种 SDK 下均为 0 KiB，nvim-dap-view 在两种 SDK 下均为 192 KiB。

| 包 | 附件字节 1 → 2 | 校验加载 ms 1 → 2 | Lua 堆 KiB 1 → 2 |
| --- | ---: | ---: | ---: |
| which-key | 59,834 → 39,312 | 1.10 → 0.86 | 90.1 → 51.5 |
| telescope | 84,755 → 66,954 | 1.49 → 1.23 | 119.2 → 90.4 |
| nvim-tree | 92,029 → 72,996 | 1.62 → 1.47 | 124.9 → 93.1 |
| nvim-dap | 84,439 → 68,194 | 1.49 → 1.33 | 110.3 → 84.4 |
| nvim-dap-ui | 40,353 → 36,790 | 1.03 → 0.97 | 60.5 → 50.5 |
| nvim-dap-view | 106,028 → 93,851 | 1.46 → 1.41 | 107.1 → 84.8 |

## 历史记录

- [v0.2.0 验证记录](https://github.com/DerckHanna/nvim-zh/blob/v0.2.0/docs/verification.md)
- [v0.1.0 验证记录](https://github.com/DerckHanna/nvim-zh/blob/v0.1.0/docs/verification.md)
