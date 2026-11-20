# Clang 工具链覆盖清单

固定组合为官方 Neovim 0.12.6 Linux x86_64 发行包、LuaJIT 2.1.1774638290、glibc 2.44、WSL2，搭配 Arch Linux `clang 23.1.5-1`。LLVM 源码为 `llvmorg-23.1.5`，对应 commit `392dfff97d29b59d77e5cac6d4b6ef2585fe7117`。四个二进制的路径、版本、平台、来源、SHA-256 和相关软件包摘要见 [toolchain.json](../manifests/toolchain.json)。[Neovim 官方发行版](https://github.com/neovim/neovim/releases/tag/v0.12.6) [LLVM 官方源码版本](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.5)

| 工具 | 固定组合中的可用入口 | 原文及版本回退 |
| --- | --- | --- |
| `clang` / `clang++` | Neovim 0.12.6 直接调用后的 quickfix/location list。涵盖已匹配的 driver、预处理/头文件、语法、类型、模板/约束、目标 ABI 和注释诊断。 | 由 `errorformat` 生成原始条目。未核实的来源、歧义、其他二进制或接口使用原文。链接器由其自身输出识别。 |
| `clangd` | 用已验证的 `serverInfo` 查看 push 诊断、相关位置、代码动作标题、悬浮标题、补全重载数、签名标题、索引和文件状态。 | 保留项目注释、声明、补全插入、修复编辑、日志与运行时生成的 AST。固定服务器的 pull 和 completion resolve 返回 `-32601`。 |
| `clang-tidy` | 独立 quickfix 和 clangd 转发。按检查名查主诊断。附加说明使用相关检查 context。独立流程保留导出、应用和复查。 | 独立命令按版本及摘要选择。转发按实际服务器和来源选择。未识别的检查说明与编辑保留原文。 |

其他 LLVM 版本、macOS、Windows、Neovim nightly 的 CLI 显示未纳入这组固定验证。历史发布的 clangd 0.1.0 词库沿用其历史匹配规则。已发布的 clangd 0.1.1 支持其附件清单声明的方法。当前开发版附加接缝用本地候选包验证。

## 源码与匹配证据

| 清单 | 范围和限制 |
| --- | --- |
| [clang-coverage.json](../manifests/clang-coverage.json) | 7,289 条 TableGen 诊断，34,872 个去重展开形态。逐条保留定义位置、严重性和警告组。排除的组件和原因写在清单中。 |
| [clangd-coverage.json](../manifests/clangd-coverage.json) | 6,663 条候选诊断，34,099 个展开形态。按组件筛选，真实可达性由样例或协议证据确认。 |
| [clangd-protocol.json](../manifests/clangd-protocol.json) | 逐方法记录能力、源码、显示入口和验证输入。实际帧、返回码和显示留在运行报告。 |
| [clang-tidy-coverage.json](../manifests/clang-tidy-coverage.json) | 471 条模块注册，另有 205 条静态分析器注册。真实二进制列出的 602 个检查名均可对应注册。模块扫描识别 903 条候选消息、153 条说明和 86 个直接含修复调用的检查。35 个检查仍有源码扫描告警，14 个诊断调用参数尚待求值。静态分析器的消息与路径追踪说明仍待盘点。 |

TableGen 展开处理 `%sub` 参数重编号、`%select`、枚举选择、复数和 `%diff`。固定版本的组合未达到展开上限。展开保留引号和参数位置，报告里的代入样例覆盖形式匹配。分支组合的真实可达性、诊断参数的全部格式和嵌套引用仍有待验证。检查工具的提取以 C++ 源码静态扫描为依据，共用诊断辅助函数和间接修复需补充人工或运行证据。

报告逐项记录来源、诊断定义或检查名、验证输入、接口、生产 Lua 匹配结果、命中的 context 和回退原因。表里的合成计数按「诊断形态 × 可见代码」计数。真实 CLI 和真实 push 单独计数。项目文字及编辑操作用原样展示验证。完整覆盖验收使用 `--require-complete`，现有词库的缺项与歧义使该门禁失败。

| 词库 | 表中合成命中 | 实际观察 |
| --- | --- | --- |
| Clang 407 条。按主诊断、driver、注释及原有词条 context 维护 | 916 条，另有 30 个参数型形态保留原文，50 条歧义，43,726 条缺译 | 70 条诊断正文命中，2 条包含栈前导仍为原文 |
| clangd 现有通用、代码专用和 LSP 界面词条 | 835 条，另有 11 个参数型形态保留原文，42,707 条未命中 | 21 条 push 中 20 条正文命中，1 条为项目 `#error` |
| clang-tidy 13 条，含检查名专用词条和应用修复提示 | 12 条匹配 5 个检查，1,141 条未命中 | 独立命令 11 条命中，TUI 另验证了两个检查的转发、附加说明以及 `modernize-use-nullptr` 修复和复查 |

## 复跑

在仓库外准备固定 LLVM 检出及证据目录。使用固定的 `llvm-tblgen`、Neovim 和四个工具，设置 `NVIM_BIN` 为官方 Neovim 路径。

~~~bash
python3 -B tools/toolchain_inventory.py coverage --source-root "$llvm"
python3 -B tools/diagnostic_inventory.py coverage --source-root "$llvm"
python3 -B tools/toolchain_catalog.py sync
python3 -B tools/toolchain_observe.py --output "$evidence/compiler.json"
NVIM_ZH_TEST_CLANGD=/usr/bin/clangd NVIM_ZH_CLANGD_RECORD="$evidence/clangd.json" make test-integration
NVIM_ZH_ROOT="$PWD" PYTHONPATH=tests/support:tools \
  python3 -B tests/workflows/clang_toolchain.py --evidence "$evidence/tui"
python3 -B tools/toolchain_coverage.py --compiler "$evidence/compiler.json" \
  --clangd "$evidence/clangd.json" --tui "$evidence/tui/中文/wire.json" \
  --report "$evidence/coverage.json" --require-complete
~~~

需要维护候选附件时用 `tools/pack_assets.py --id <工具> --version <版本> --output <仓库外路径>`。`clang`、`clangd`、`clang-tidy` 各有独立附件。测试用 `:NvimZhPacks import` 进入正式安装路径。正式 Release、CI 和当前运行记录见[验证记录](verification.md)。
