# Clang 工具链覆盖清单

固定组合为官方 Neovim 0.12.6 Linux x86_64 发行包、LuaJIT 2.1.1774638290、glibc 2.44、WSL2，搭配 Arch Linux `clang 23.1.5-1`。LLVM 源码为 `llvmorg-23.1.5`，对应 commit `392dfff97d29b59d77e5cac6d4b6ef2585fe7117`。四个二进制的路径、版本、平台、来源、SHA-256 和相关软件包摘要见 [toolchain.json](../manifests/toolchain.json)。[Neovim 官方发行版](https://github.com/neovim/neovim/releases/tag/v0.12.6) [LLVM 官方源码版本](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.5)

| 工具 | 固定组合中的可用入口 | 原文及版本回退 |
| --- | --- | --- |
| `clang` / `clang++` | Neovim 0.12.6 直接调用后的 quickfix/location list。包含栈、驱动和前端参数提示、预处理、语法、类型、模板与约束、目标 ABI 和相关说明使用已匹配的词条。 | 由 `errorformat` 生成原始条目。未核实的来源、歧义、其他二进制或接口使用原文。Clang 的 `-v` 记录了 GNU ld、GNU as 的实际调用。 |
| `clangd` | 用已验证的 `serverInfo` 查看 push 诊断、相关位置、代码动作标题、悬浮标题、补全文档中的头文件来源、签名标题、索引和文件状态。 | 保留项目注释、声明、补全插入、修复编辑、日志与运行时生成的 AST。固定服务器的 pull 和 completion resolve 返回 `-32601`。 |
| `clang-tidy` | 独立 quickfix 和 clangd 转发。按检查名查主诊断和附加说明。空指针静态分析有独立列表和路径说明。 | 独立命令按版本及摘要选择。clangd 运行模块检查。未识别的检查说明与编辑保留原文。 |

其他 LLVM 版本、macOS、Windows、Neovim nightly 的 CLI 显示未纳入这组固定验证。官方目录提供 SDK 2 附件。原生补全候选与回调仍使用服务器字段。

## 源码与匹配证据

| 清单 | 范围和限制 |
| --- | --- |
| [clang-coverage.json](../manifests/clang-coverage.json) | 7,289 条 TableGen 诊断，34,872 个去重展开形态，另有 2 个包含栈前导。逐条保留定义位置、严重性和警告组。 |
| [clangd-coverage.json](../manifests/clangd-coverage.json) | 6,663 条候选诊断，34,099 个展开形态。按组件筛选，真实可达性由样例或协议证据确认。 |
| [clangd-protocol.json](../manifests/clangd-protocol.json) | 逐方法记录能力、源码、显示入口和验证输入。实际帧、返回码和显示留在运行报告。 |
| [clang-tidy-coverage.json](../manifests/clang-tidy-coverage.json) | 471 条模块注册和 205 条分析器注册，真实二进制列出的 602 个名字均有对应项。模块盘点识别 974 条候选消息，其中 164 条附加说明。113 个检查找到修复调用或辅助函数。35 个扫描告警和 14 个未求值调用均已核对。131 个已启用静态分析器检查的消息盘点全部完成并记录在 [analyzer_audit.json](../translations/toolchain/analyzer_audit.json)（共 1,715 条源码核对消息；116 个检查输出诊断，15 个仅做符号状态建模）。 |

TableGen 展开处理 `%sub` 参数重编号、`%select`、枚举选择、复数和 `%diff`。固定版本的组合未达到展开上限。部分参数按实际类型、声明名和序数渲染，相关测试保留原始参数。静态展开的各分支仍需分别确认可达性和实际参数格式。检查工具的清单同时记录共用辅助函数、间接修复和拼接诊断的文本来源与调用位置。

报告逐项记录来源、诊断定义或检查名、验证输入、接口、生产 Lua 匹配结果、命中的词条及回退原因。合成计数按「诊断形态 × 代码」统计。CLI 正文复验、独立 LSP 探针、TUI 原始协议复验及 TUI 屏幕各自留证。完整门禁检查缺译、歧义、实际工具身份、启停对照、协议结果与已启用分析器的盘点状态。当前固定组合完整门禁通过（`TOOLCHAIN_COMPLETE=PASS`，退出码 `0`）。

| 词库 | 表中合成命中 | 实际观察 |
| --- | --- | --- |
| Clang 33,543 条 | 44,693 条命中（`matched_source_ids=7,261`），31 条纯参数正文或自由文本保留原文，0 条缺译，0 条歧义 | 两个驱动共 48 次调用，生产匹配器命中 172 个真实输出项，保留 14 条项目原文、8 条修复编辑和 2 条链接器/汇编器消息。嵌套包含栈、参数建议、带撇号的路径和模板约束说明另经 TUI 验证。 |
| clangd 33,016 条 | 43,541 条命中（`matched_source_ids=6,652`），12 条预期保留原文，0 条缺译，0 条歧义 | 独立探针取得 21 条主诊断，主诊断和附加说明合计 30 条命中，另有 1 条 `#error` 原文；TUI push 命中 14 条及 2 条碰撞原文。真实 TUI 核对了 `workspace/applyEdit`、模板相关说明和碰撞原文。 |
| clang-tidy 3,103 条 | 3,104 条命中（`matched_source_ids=587`，覆盖 471 个模块检查和 116 个有消息输出的分析器检查），0 条缺译，0 条歧义 | 独立命令 20 条命中。TUI 协议中 10 条转发主诊断或附加说明命中。两种方式均验证应用修复与复查，独立流程还核对空指针路径和 YAML。 |

固定 clangd 的三个未实现请求均实测返回 `-32601`。独立客户端契约核对 document pull、workspace pull 与 completion resolve 的成功响应。源码与 TUI 协议证实该服务器发送 `window/showMessage`。`window/showMessageRequest` 和 `window/logMessage` 的固定组合结论依据编译服务器的发送绑定清单和本次协议记录，客户端的成功处理使用独立测试。

当次完整门禁 `tools/toolchain_coverage.py --require-complete` 返回 `0`（`TOOLCHAIN_COMPLETE=PASS`）：三个词库合成匹配 `0` 缺译、`0` 歧义，`evidence_gaps = []`，`enabled_analyzer_audit_gaps = 0`，`registration_gaps = 0`。具体证据见[验证记录](verification.md)。

## 复跑

工具链译文只在 `translations/toolchain/zh_CN.json` 编辑。TableGen 摘要和诊断例外按上游 ID 或分支登记，独立 clang-tidy 译文按检查名登记，已审定的界面文案及补充出处使用 `reviewed`。分析器逐项来源记录在 `analyzer_audit.json`。生成器直接读取这些输入，并可在空目录写出完整 PO。

在仓库外准备固定 LLVM 检出及证据目录。两份源码与 llvm-tblgen 的摘要锁见 `manifests/toolchain.json`。先为当前发行基线及相邻基线分别生成。相邻基线生成只用于构建再现，运行时组合仍以本页固定版本与方法清单为准。

~~~bash
python3 -B tools/toolchain_inventory.py coverage --source-root "$llvm" \
  --tblgen "$tblgen" --output "$evidence/inventory"
python3 -B tools/toolchain_inventory.py coverage --source-root "$llvm_previous" \
  --baseline llvmorg-23.1.4 --tblgen "$tblgen_previous" --output "$evidence/previous-inventory"
python3 -B tools/toolchain_catalog.py sync --inventory "$evidence/inventory" --output "$evidence/po"
python3 -B tools/toolchain_catalog.py sync --inventory "$evidence/previous-inventory" --output "$evidence/previous-po"
~~~

用独立目录重跑并逐字节比较同一基线。比较发布前后的检出可输出语义差异。运行下列固定 Neovim 与 LLVM 工作流继续核对显示、协议和实际注册结果。

~~~bash
python3 -B tools/toolchain_catalog.py diff --before "$previous_checkout" --after "$PWD" --output "$evidence/diff.json"
python3 -B tools/toolchain_observe.py --output "$evidence/compiler.json"
NVIM_ZH_TEST_CLANGD=/usr/bin/clangd NVIM_ZH_CLANGD_RECORD="$evidence/clangd.json" \
  make test-contract test-integration >"$evidence/contracts.log" 2>&1
NVIM_ZH_ROOT="$PWD" PYTHONPATH=tests/support:tools \
  python3 -B tests/workflows/clang_toolchain.py --assets "$evidence/candidates" --evidence "$evidence/tui"
python3 -B tools/toolchain_coverage.py --compiler "$evidence/compiler.json" \
  --clangd "$evidence/clangd.json" --tui "$evidence/tui/中文/wire.json" \
  --contracts "$evidence/contracts.log" --report "$evidence/coverage.json" --require-complete
~~~

语义差异报告按诊断 ID、检查名、context 和原文标记新增、移除、变化及译文冲突。盘点命令共用已验证的 TableGen 数据，并将输出写入指定目录。需要维护候选附件时用 `tools/pack_assets.py --id <工具> --version <版本> --output <仓库外路径>`。`clang`、`clangd`、`clang-tidy` 各有独立附件。省略 `--assets` 时，TUI 会生成测试版本的本地附件。使用真实候选时，启停对照同时核对三个附件的摘要。正式 Release、CI 和当前运行记录见[验证记录](verification.md)。
