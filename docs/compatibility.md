# 兼容性与验证边界

## 支持范围

| 项目 | 支持口径 |
|---|---|
| Neovim | 0.12+；完整翻译和 Help 基线固定为 0.12.6 |
| 安装/更新 | 内置 `vim.pack`；其他管理器不作为本项目的正式安装/更新路径 |
| 自动原生 gettext | Linux/glibc + LuaJIT；必须通过真实 MO 哨兵查询才算生效 |
| 中文 Help / Lua UI | 不依赖原生 FFI 能力；原生部分失败时独立降级 |
| nightly | CI 中仅作实验性预警，不形成稳定兼容承诺 |
| Windows、macOS、musl、无 FFI 构建 | 原生自动接线能力依赖本机环境，下表记录逐平台实测 |

| 环境 | Neovim | 原生探针 | 中文 Help、Lua UI 与回退 |
|---|---|---|---|
| Linux x86_64，glibc 2.44，WSL2 | 官方 0.12.6 | 中文 E482/E576/E136/E5005、欢迎页及 12 项运行时键修复通过 | 中文 Help、Lua UI 和英文回退通过 |
| Windows 11 x86_64，NT 10.0.26300 | 官方 0.12.6 | 原生接线报告 `unsupported`，E482 保留英文 | 中文 `options`、英文 `credits`、中文通知、未知文案和 teardown 通过 |
| macOS 15.8.2 arm64，GitHub Actions | 官方 0.12.6 | 原生接线报告 `unsupported`，E482 保留英文 | 通过系统路径别名启动后，中文 `options`、英文 `credits`、中文通知、未知文案和 teardown 均通过。[CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44676795841) |
| Alpine Linux edge x86_64，musl 1.2.6 | Alpine 0.12.2-r1 | 缺少 glibc 符号，原生接线报告 `unsupported`，E482 保留英文 | 中文 `options`、英文 `credits`、中文通知、未知文案和 teardown 通过 |

项目不再维护 0.10/0.11 的独立基础入口，也不保留旧命令、旧 Lua API 或旧测试目录的兼容层。旧版本的历史测试记录不能作为当前版本通过证据。

## 机器清单代表什么

### 中文 Help

`manifests/help_inventory.json` 当前记录固定 0.12.6 runtime 的 135 篇文档：133 篇在编辑 manifest 中标为 `complete`，2 篇有证据地排除（`credits.txt`、`uganda.txt`）。项目自有 `nvim-zh.txt/.cnx` 不计入这 133 篇。

`complete` 表示维护者声明的翻译状态，并有 tag、示例块、链接、索引和固定上游摘要等结构契约。它不等于逐句语义审校，也不等于“全部 Neovim 已汉化”。运行时缺少中文 tag 时自然回退英文。

### 核心 gettext

固定上游目录有 1 985 条消息，其中 1 855 条上游已译、130 条上游空缺。本项目编辑源补充 118 条，另外 12 条由上游明确标注不翻译。

`manifests/native.json` 记录固定二进制的键核对。76 条匹配裸键，25 条同时需要带错误码前缀的键，2 条来自 runtime，15 条旧键未直接匹配。其中 12 条已在固定 Neovim 复现并以实际运行时键修复，3 条 ShaDa 旧键仍无可复现入口，清单保留固定源码定位。

合并 MO 使用 Neovim 原生 gettext 机制，从用户数据目录的已验证快照读取，不替换系统 MO。

## 第三方插件

| 插件 | 固定 commit | 已验证接缝边界 |
|---|---|---|
| which-key | `3aab2147e74890957785941f0c1ad87d0a44c15a` | preset、动态数量、底部提示、marks/Register 标签、通知、健康检查和 3 篇中文帮助 |
| Telescope | `1e1bab730218eaf97fce743be3f56e51075928ac` | 首开与动态标题、精炼、映射浮窗、Git 和 Register 提示、通知、操作输出、健康检查和 3 篇中文帮助 |
| nvim-tree | `dbc9d96a3633c2de85f409416ebd4a3aacf4220a` | 默认映射、通知、文件操作、文件信息、Window 选择、帮助浮窗、隐藏统计和 4 篇中文帮助 |
| nvim-dap | `cfa2d58f4537aca6ca83e2de1a0d9f1491121264` | 通知、选择器、REPL、输入、quickfix、健康检查、Widget、诊断前缀和 4 篇中文帮助 |
| nvim-dap-ui | `cc9dd33aade7f20bae414d0cba163bc60d4d4b43` | 固定渲染文案、映射、浮窗、选择器、Window 提示、通知和 3 篇中文帮助 |
| nvim-dap-view | `1c3b9cc295303fc173f24d442739a8557e23e987` | 监视、作用域、调试面板、键位、异常、Help 及 CodeLLDB 1.12.3 的固定显示标签 |
| lazy.nvim | `306a05526ada86a7b30af95c5cc81ffba93fef97` | `User LazyLoad` 生命周期桥接 |
| nvim-cmp | `2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3` | inventory-only，实测公共 formatter 与输入数据契约 |

固定组合和实际检查的源码 SHA-256 见 `manifests/adapters/`。正式显示 API 与固定源码接缝的证据各自记录。详细范围和加载方法见[第三方插件适配](adapters.md)。

## 诊断、LSP 与外部工具

诊断与 LSP 适配按诊断代码和显示文本匹配译文。诊断列表使用 Neovim 0.12 的 formatter，原生补全使用同版本提供的显示转换入口。固定样例和真实服务器测试只统计实际验证的文本。原始 LSP 诊断、日志和外部编译器的 stdout/stderr 继续使用上游文本。

真实 clangd pull 的支持取决于服务器能力；不支持的方法要报告真实错误，不能把它写成成功。测试必须同时保留成功 pull 反例，避免用 `and/or` 之类表达式让已知消息断言失效。

声明工具目标的 clangd 汉化包使用 LSP `serverInfo` 和协议方法选择词库显示面。已验证目标为 `clangd version 23.1.5 linux x86_64-pc-linux-gnu`。其他版本、缺失身份和未验证方法使用服务器原文。历史 0.1.0 clangd 附件仍按当时的词库规则工作，可用面板查看区别和回退原因。

## 验证与 SKIP 规则

- 默认 `make test` 是离线套件，包含真实本地 PTY 和临时 Git 仓库的 vim.pack 集成，不要求第三方源码或网络。
- `make test-upstream` 要求固定第三方源码目录真实存在；缺环境是未完成/失败，不得以 SKIP 退出成功。
- 真实 native/clangd 检查有独立显式入口。只有平台或版本确实不适用时才允许 SKIP；版本探测失败、空输出、超时和工具错误不得降级为 SKIP。
- CI 配置存在不等于 CI 已在本机或 GitHub 实际通过。没有实际执行的平台、版本或网络检查不列为 PASS。
- 当次重构的命令、结果和剩余限制记录在[验证报告](verification.md)；历史记录不作为当前通过凭证。
