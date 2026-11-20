# 验证记录

## 0.1.0 验收（2026-11-20）

本地环境为 Arch Linux x86_64 / glibc 2.44（WSL2），使用通过 SHA-256 校验的 Neovim 官方 0.12.6 压缩包与 CodeLLDB 官方 1.12.3 VSIX。固定插件及依赖由 `tools/adapter_tool.py lock all --json` 和 `fetch --lock … --source-root …` 获取。命令从独立用户目录启动 Neovim。

| 检查 | 实际结果 |
| --- | --- |
| `make check-syntax check-translations check-native` | PASS。47 个 Python、10 个 Shell、110 个 Lua 文件通过语法检查。8 个词库共 1 335 条，核心 gettext 输入通过校验。 |
| `make build-resources check-resources check-reproducible sync release-check` | PASS。主包资源 142 个文件，Lua、MO 和完整资源逐字节复现，离线同步无变动。移出的研究资料保留在仓库外。 |
| `NVIM_ZH_TEST_NATIVE_RUNTIME=1 NVIM_ZH_TEST_CLANGD=/usr/sbin/clangd make test` | PASS。62 个 Lua 规格、117 个 Python 用例，验证用户配置、更新取消与回退、失败候选与并发、真实中文消息及欢迎页。检查 133 篇核心 Help 的结构及固定上游摘要。系统 MO 探针在官方压缩包中缺少其预期文件，报告 SKIP。使用项目 MO 的独立原生消息和欢迎页测试通过。 |
| 同一次 `make test` 的 clangd 探针 | clangd 23.1.5 对 14 个样例发布 17 条 push 诊断，显示契约命中 16 条，保留原始协议。真实编辑器打开中文错误、警告、悬浮和 quickfix，并应用修复。pull 返回 `-32601`，成功 pull 走独立契约。 |
| 汉化包离线与失败恢复 | 真实终端使用本地发布附件和模拟索引，验证初次打开离线、按需下载、热更新、关闭面板后继续下载、暂停与恢复、离线回滚、取消与确认卸载。Lua 规格验证入口执行失败恢复包登记、拒绝未授权 Lua 与摘要错误，以及随后可重新导入。 |
| `NVIM_ZH_ADAPTER_SOURCE_ROOT=… NVIM_ZH_ADAPTER_REPORT=… make test-upstream` | PASS。67 个记录，包含 59 个终端场景和 116 个汉化启停或单组终端执行。首次使用旧本地检出时缺少固定 nvim-tree 修订，退出非零。使用新锁定源码目录后完整矩阵通过。 |
| `bash benchmarks/run.sh` | PASS。202 个 UI 事件保留 history 和 cmdheight。200 次基线 0.252 ms，观察开启 0.179 ms。 |

`nvim-dap-view` 的 `codelldb` 和 `interaction` 均在汉化启用和关闭时通过。真实调试命中第 8 行，展开变量与寄存器，单步并继续至退出码 0。此前环境在启动阶段报告 `failed to send the handshake ack`。本轮同版本 VSIX 完成了实际子进程调试，保留了所有终端和协议断言。两组 `interaction` 使用同一个经源文件摘要验证的装载接缝，英文组的接缝仅保留虚拟行参数等兼容处理。直接调用 Neovim API 仍可复现 0.12.6 拒绝 `virt_lines_overflow = "wrap"`。

固定 CodeLLDB 附件的 `liblldb.so` 含该错误字符串。LLVM 源码中对应 `GDBRemoteCommunicationClient::HandshakeWithServer` 发送初始 ACK 失败，发生在开始读取子调试器响应之前。历史运行没有保留足以确定连接提前关闭原因的进程或系统调用记录。[LLVM 源码](https://github.com/llvm/llvm-project/blob/7a941dfb2877a0b8cf30323fefa85ad019e0b0f5/lldb/source/Plugins/Process/gdb-remote/GDBRemoteCommunicationClient.cpp#L88-L125)

发布提交 `631a516` 的固定版离线和上游 CI 均通过。实验性 nightly 在补全契约的模拟客户端处失败，运行时新增了对 `server_capabilities` 的读取。[CI 运行](https://github.com/DerckHanna/nvim-zh/actions/runs/44673762104)

七个 0.1.0 汉化包均从正式 Release 下载地址校验了大小和 SHA-256。官方目录 `86f1cf9` 上线后，新用户目录通过 `vim.pack.add` 安装主包，显式刷新默认官方索引，仅下载 Telescope，然后暂停和恢复。断网重启保留所选资源。另一全新用户目录在关闭网络后打开中文包管理 Help，并导入下载好的 clangd 附件。主包正式 tag 的公开源码归档通过发布检查，共 541 个文件。[官方目录](https://github.com/DerckHanna/nvim-zh/blob/86f1cf9f00a39c1f6e7ba07a234ed454ef623e6b/catalog.json) [主包 Release](https://github.com/DerckHanna/nvim-zh/releases/tag/v0.1.0)

## 工作流与维护验收（2026-11-20）

| 任务 | 命令、环境与实际结果 |
| --- | --- |
| clangd 源码盘点 | `python3 -B tools/diagnostic_inventory.py coverage --source-root <LLVM 检出>` 以 `llvmorg-23.1.4` / `7a941dfb` 生成 6 663 个诊断和 15 736 个变体。41 个诊断的展开达到上限。 |
| clangd 翻译匹配 | `python3 -B tools/diagnostic_coverage.py --observations <运行记录> --report <输出>` 调用实际 Lua 查找。盘点包括 252 条通用诊断词条、11 条与源码诊断码匹配的词条、历史 context 和 LSP UI 词条。合成参数命中 406 个诊断的 669 个变体，其中 656 个命中通用模板，13 个命中专用 context。11 个自由文本变体预期保留原文，其中包括用户写的 `#error` 内容。 |
| 真实 clangd | `NVIM_ZH_TEST_CLANGD=/usr/bin/clangd NVIM_ZH_CLANGD_RECORD=<输出> make test-integration`。Arch 软件包 `clang 23.1.5-1` 的服务器标识为 `clangd version 23.1.5 linux x86_64-pc-linux-gnu`，二进制 SHA-256 为 `40b41eed884d7bcab758c571ea2828fec9bb02f30c66e3e79489af04978972b9`。15 个样例收到 21 条 push 诊断，20 条正文命中。补齐初始化窄化、显式转换和构造函数候选说明。实际编辑器通过诊断、相关位置、修复、悬浮、重载补全、签名、索引进度和模拟未知版本回退。pull 返回 `-32601`，独立契约覆盖成功路径。 |
| C/C++ 终端 | `python3 -B tests/workflows/cpp_tui.py`。官方 Neovim 0.12.6、clangd 23.1.5、GCC 16.2.1、GNU Make 4.4.1、官方 CodeLLDB 1.12.3 和固定 DAP 插件。两组在中文路径项目中查阅 Help、搜索编辑、查看诊断原文和错误码、应用修复、构建、quickfix 跳转和调试。失败构建退出码 2，修复后为 0。两组跳到第 3 行第 32 列，LSP 原始对象字段一致。第 3 行断点的 `counter = 7`，继续至退出码 0。中文组用本地词库验证热更新和回滚，注入未知版本并检查状态理由。 |
| pytest、Ruff 与 Git 冲突 | `python3 -B tests/workflows/python_git_tui.py`。选用 Neovim 0.12.6 自带编译器支持的 pytest 9.0.2 与 Ruff 0.15.0，两者都有可固定的本地环境、明确的退出码和位置。两组分别从测试第 2 行断言和 Ruff 第 1 行 `F401` 的失败退出码 1 到修复后的 0。Git 2.56.1 的临时分支合并返回 1，定位冲突第 1 行，确认解决后的暂存内容和空冲突索引。位置、原文和退出状态通过差分。 |
| 核心 gettext | `make audit-native` 核对原 15 个未确认键。`NVIM_ZH_TEST_NATIVE_RUNTIME=1 make test-integration` 和独立英文/中文探针覆盖 12 个修复后的键，包括 E513、E1136、E5100/E5101、E5114、Lua 回调、`--server` 和 E575。3 个 ShaDa 旧键仅有源码移除或重构证据，见 `manifests/native.json`。 |
| 核心 Help | 固定 0.12.6 的 133 篇全量结构契约通过。按清单的 10 个主题逐批抽查对齐段落，机器核对了 164 个可配对的字面默认值。修订 `starting` 的日志路径、`usr_24` 的删除位置和 `usr_25` 的实际插入换行。语义审阅覆盖样本与所修主题，其他段落仍需全文审校。 |
| 平台 | 在隔离环境执行 `nvim --headless -u NONE -i NONE -n -l tests/platform/localization.lua`。Windows 11 x86_64 和 macOS 15.8.2 arm64 使用官方 0.12.6，Alpine edge x86_64 使用 Neovim 0.12.2-r1 与 musl 1.2.6。三组通过中文 Help、英文 Help 回退、Lua UI 和原文通知回退。三组的原生后端均报告 `unsupported`，E482 保留英文。macOS 首次因系统目录别名拒绝了快照路径，修复后从系统别名路径复跑通过。[macOS CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44676795841) |

工作流说明和复跑环境见[中文操作指南](workflows.md)与[测试文档](testing.md)。

## 历史全量复审（2026-11-19）

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
