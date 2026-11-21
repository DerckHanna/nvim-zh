# 验证记录

## P2 紧凑词库与 SDK 2 验收（2026-11-21）

本轮以 `main@f73be7c`（P1 闭环基线）和 `origin/packs@a7c9bab` 为对照基线，实施 P2.1 紧凑词库重构（[catalog.lua](../lua/nvim-zh/catalog.lua)、[engine.lua](../lua/nvim-zh/engine.lua)、[packs.lua](../lua/nvim-zh/packs.lua)）与 P2.2 路线 B 单层紧凑 SDK 2 附件格式（[pack_store.lua](../lua/nvim-zh/pack_store.lua)、[resource_bundle.py](../tools/resource_bundle.py)、[pack_assets.py](../tools/pack_assets.py)，候选版本 `0.2.0`）。固定对照环境为官方 Neovim 0.12.6（`sha256: 2e150e924a93930295deff9ca3c02c8828590ce3d04ce7b3ef49c8804adde973`）、Linux x86_64/glibc 2.44（WSL2）与摘要匹配的 LLVM 23.1.5；全部原始日志与机器可读结果位于 `/tmp/nvim-zh-p2-verify`。

### P2 同机前后性能对照（官方 Neovim 0.12.6，隔离 XDG，`PYTHONDONTWRITEBYTECODE=1`）

同机三组对照使用相同官方 Neovim 0.12.6：`p1_sdk1`（`git archive f73be7c` + 已验收 SDK 1 `clang 0.1.0` / `clangd 0.1.2`）、`p2_sdk1`（当前工作树 + 相同 SDK 1）、`p2_sdk2`（当前工作树 + 候选 SDK 2 `clang 0.2.0` / `clangd 0.2.0`）。原始读数见 `/tmp/nvim-zh-p2-verify/performance.json`。

| 负载 | `p1_sdk1`（`f73be7c`） | `p2_sdk1`（存量 SDK 1） | `p2_sdk2`（候选 `0.2.0`） | 变化 / 预算判定 |
| --- | ---: | ---: | ---: | --- |
| 两包冷启动 / 5 进程复用中位数（最大） | `263.13 / 59.87 (60.33) ms` | `287.36 / 59.91 (62.76) ms` | `281.84 / 62.74 (65.26) ms` | 延迟启动无回归，启动后 RSS `21.60 MiB` / Lua 堆 `1.80 MiB`（PASS） |
| 显式首查 `clang_get`（5 次 P50 / P95） | `144.91 / 147.44 ms` | `94.87 / 97.92 ms`（-34.5%） | **`44.03 / 48.04 ms`** | **-69.6% P50 / -67.4% P95**（预算 `≤45 / ≤55 ms`，PASS） |
| 显式首查 `clangd_get`（5 次 P50 / P95） | `146.42 / 168.91 ms` | `100.80 / 107.76 ms`（-31.2%） | **`44.26 / 45.27 ms`** | **-69.8% P50 / -73.2% P95**（预算 `≤45 / ≤55 ms`，PASS） |
| 首个单错误 Clang 构建（主线程返回 / 中文就绪 P50） | `18.93 / 177.72 ms` | `19.08 / 126.55 ms`（-28.8%） | **`18.30 / 73.09 ms`** | 主线程返回 -3.3%，中文就绪 **-58.9%**（超 ≥55% 相对目标，PASS） |
| 真实 clangd `after_attach_ms`（5 次 P50 / P95） | `165.56 / 171.63 ms` | `104.74 / 112.51 ms`（-36.7%） | **`51.77 / 55.37 ms`** | **-68.7% P50**（预算 `≤65 ms`，PASS） |
| 真实 clangd `visible_ms`（5 次 P50 / P95） | `178.94 / 184.74 ms` | `118.20 / 125.73 ms`（-33.9%） | **`65.25 / 69.20 ms`** | **-63.5% P50**（预算 `≤80 ms`，PASS） |
| 单域载入后 GC 后 Lua 堆 / RSS / Peak RSS | `33.99 / 55.73 / 61.93 MiB` | `10.62 / 36.71 / 53.99 MiB` | **`10.62 / 28.19 / 33.83 MiB`** | Lua **-68.8%**、RSS **-49.4%**（预算 `≤12 / ≤30 MiB`，PASS） |
| 双域载入后 GC 后 Lua 堆 / RSS / Peak RSS | `59.44 / 83.53 / 102.33 MiB` | `17.14 / 43.80 / 61.18 MiB` | **`17.16 / 35.11 / 40.77 MiB`** | Lua **-71.1%**、RSS **-58.0%**、Peak **-60.2%**（预算 `≤18 / ≤36 / ≤45 MiB`，PASS） |
| 1,000 条诊断虚拟文本 / QF / Loc P95（启用） | `30.68 / 13.69 / 27.44 ms` | `17.29 / 16.71 / 19.18 ms` | **`15.90 / 14.91 / 17.80 ms`** | VT **-48.2%**、Loc **-35.1%**（零回归，PASS） |
| 3,001 项 Clang 列表打开 P50 / P95（启用） | `0.60 / 0.76 ms` | `0.61 / 0.75 ms` | **`0.62 / 0.83 ms`** | 零回归（预算 `≤15 ms`，PASS） |
| 500 项原生补全 P50 / P95（启用） | `1.50 / 10.14 ms` | `1.50 / 7.47 ms` | **`1.51 / 6.71 ms`** | **-33.8% P95**（PASS） |
| SDK 2 损坏回退至已验证 SDK 1 `0.1.2`（5 次 P50 / P95） | — | — | `119.79 / 121.87 ms` | 1 字节篡改经 SHA-256 拒绝并回退至 `0.1.2` 译文就绪（PASS） |
| `make check-translations`（3 次中位数） | — | — | `2.46 s`（`2.41–2.47 s`） | 预算 `≤3.0 s`（PASS） |

### SDK 1 与 SDK 2（`0.2.0`）双次复现与全量门禁（2026-11-21）

| 检查 | 结果 |
| --- | --- |
| 空 `LOCPATH` 全量离线门禁：`make check-syntax check-translations check-native check-resources check-reproducible test release-check` | PASS（56 Python / 10 Shell / 122 Lua 语法通过，含新增 `sdk2_spec.lua` 与 `test_pack_assets.py`，发布候选 592 个文件，`/tmp/nvim-zh-p2-verify/gates.log`）。 |
| 离线 `make sync` | PASS（`SYNC_STATUS=OK changes=0 network=false`，`sync.log`）。 |
| 真实 native runtime 与真实 clangd（空 `LOCPATH`，`NVIM_ZH_TEST_NATIVE_RUNTIME=1 NVIM_ZH_TEST_CLANGD=/usr/bin/clangd`） | PASS（项目 MO 探针与欢迎页通过；系统 locale MO 探针因空 `LOCPATH` / 官方包缺系统 MO 记 SKIP；15 样例 21 条 push 诊断原数据不变，pull 返回 `-32601`，`real-native-clangd.log`）。 |
| SDK 1 双次复现 + SDK 2（`0.2.0`）双次复现与合并索引 | PASS。SDK 1 逐字节复现且与 `origin/packs@a7c9bab` 摘要一致：`clang 0.1.0`（`ccaeb17c...`，8.6 MiB）、`clang-tidy 0.1.0`（`91eb1d39...`，827 KiB）、`clangd 0.1.2`（`0dd6344f...`，8.7 MiB）。SDK 2 候选 `0.2.0` 双次逐字节一致：`clang 0.2.0`（`e7ed12a1...`，5.7 MiB，-34%）、`clang-tidy 0.2.0`（`7eb609a6...`，492 KiB，-40.5%）、`clangd 0.2.0`（`26371615...`，5.7 MiB，-35%）、合并 `catalog.json`（`d595e181...`）。 |
| 完整 Clang 工具链门禁（`toolchain_observe.py` + `clang_toolchain.py` SDK 1 & SDK 2 双组 PTY + `toolchain_coverage.py --require-complete`） | PASS（48 次驱动调用，602 个 clang-tidy 检查零缺口，SDK 1 与 SDK 2 真实 PTY 启停对照均 `CLANG_TOOLCHAIN_TUI_DIFFERENTIAL=PASS`，官方 0.12.6 上 91,654 样本零缺译/零歧义/零证据缺口，`TOOLCHAIN_COMPLETE=PASS`）。 |
| 固定第三方上游矩阵（`make test-upstream`，官方 0.12.6） | PASS（67/67 全通过，`upstream.json`）。 |
| C++/DAP（`cpp_tui.py`）与 Python/Git（`python_git_tui.py`）终端工作流（官方 0.12.6） | PASS（启停两组跳转、修复、退出码 2→0、CodeLLDB 调试退出码 0、pytest/Ruff/Git 冲突解决完全一致，`cpp-tui.log`、`python-git-tui.log`）。 |
| 本机 Linux 平台探针（`tests/platform/localization.lua` 与 `tests/platform/packs.lua`） | PASS（`native=ok`，`sdk1=synthetic+published(0.1.0,0.1.1,0.1.2)` + `sdk2=synthetic`，覆盖跨 SDK 损坏回退、原地修复、离线回滚及硬链接/EEXIST/过期代次/EPERM）。 |
| 远端/跨平台（Windows 11、Alpine musl、macOS 15.8.2 CI、Neovim nightly CI） | SKIP / 待推送后复测（本轮尚未提交/推送，远端 CI 尚未在 P2 工作树上运行；候选 `0.2.0` 附件仅存本地 `/tmp/nvim-zh-p2-verify/sdk2-a`，待明确授权后再发布）。 |

## 架构演进验收（2026-11-21）

本轮以 `da04760` 和 `origin/packs@a7c9bab` 为基线，复核并补齐 P0/P1 验收与首用/P2 量化。Linux 固定组合在独立 XDG 和临时项目中使用官方 Neovim 0.12.6、Linux x86_64/glibc 2.44 和摘要匹配的 LLVM 23.1.5；原始日志与机器可读结果分别位于 `/tmp/nvim-zh-final-verify`（完整门禁、平台、工具链、上游与终端工作流）、`/tmp/nvim-zh-evolution.rerun`（同机前后性能对照与真实 clangd 首用）、`/tmp/nvim-zh-evolution.0TDBos`（前次演进记录）和 `/tmp/nvim-zh-generation.9WcV8h`（23.1.4/23.1.5 相邻基线与历史附件复现）。

### P0 功能对照与复跑修复

- 真实诊断、CLI quickfix 和 loclist 对照覆盖中文显示、原始条目、用户 formatter 的过滤（`nil`）、改写与异常传播、混合来源、多客户端同位歧义回退、列表追加失效、Window 独立 loclist、选择与跳转，核对了构建的输出和退出状态。复核补齐 `tests/contract/diagnostics/list_projection_spec.lua`，并修复通过 `setup()` 关闭 `diagnostics.lists` 或 `compiler` 时未释放自有 `quickfixtextfunc` 及编译器 autocmd/异步代次的问题。
- 真实 clangd 对照核对了线上数据、`LspProgress`、`client.progress`、`fileStatus`、代码操作、悬浮、补全与签名标题；下游回调和 `vim.diagnostic.get()` 均接收上游原对象。
- 故障注入覆盖原生失败、登记读取、适配器应用、资源持久化、原生部分恢复和旧回调延迟。取消回调可再次 `setup()` 或 `check()`，合并的同步回调收到最后实际应用的结果。
- 固定索引对照覆盖未验证和已验证客户端并存、当前 Buffer 优先、显式历史版、同版本不同摘要、双进程竞争登记与延迟准备回退。新增 `tests/integration/packs/deferred_spec.lua` 验证大工具包延迟启动、准备中英文回退、`teardown`/停用取消、换代作废、同步 `translate()` 无网准备及损坏快照回退；修复损坏快照在重新导入同一有效附件时未能原地替换的问题，补齐 `tests/integration/packs/store_spec.lua` 回归。

### P1 平台与 Nightly 接缝漂移

| 环境 | Neovim | `tests/platform/localization.lua` | `tests/platform/packs.lua`（含已发布 `clangd` 0.1.0/0.1.1/0.1.2） |
| --- | --- | --- | --- |
| Linux x86_64，glibc 2.44（WSL2） | 官方 0.12.6 | PASS（native=ok，中文 E482、Help、UI） | PASS（摘要拒绝、损坏回退、原地修复、硬链接/EEXIST/过期代次/缺失能力报错） |
| Windows 11 x86_64，NT 10.0.26300 | 官方 0.12.6（`nvim.exe`） | PASS（native=unsupported，英文 E482、中文 Help/UI） | PASS（同上，真实 NTFS 文件系统与已发布历史附件） |
| Alpine edge x86_64，musl 1.2.6 | Alpine 0.12.2-r1（`bwrap` 隔离） | PASS（native=unsupported，缺 `gnu_get_libc_version`，Help/UI 通过） | PASS（同上，真实 musl 环境与已发布历史附件） |
| macOS 15.8.2 arm64（GitHub Actions，`c967a7c`） | 官方 0.12.6 | PASS（`native=unsupported`，英文 E482、中文 Help/UI） | PASS（`sdk1=synthetic+published(0.1.0,0.1.1,0.1.2)`；修复 `fs.safe` 放行 macOS 顶层系统目录别名 `/var`/`/tmp`/`/etc` 后，在 `/var/folders/...` 路径下通过摘要拒绝、损坏回退、原地修复、硬链接/EEXIST/过期代次/缺失能力报错）。[macOS CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44854071678) |
| Linux x86_64，Neovim nightly（预警） | `v0.13.0-dev` | PASS（native=ok） | PASS；本机全套离线扫测与远端 `c967a7c` nightly 预警一致：`test-unit`、`test-e2e` 与 `setup_spec.lua` 通过，固定 0.12.6 runtime 接缝规格（`diagnostic.lua`/`lsp/handlers.lua`/`lsp/buf.lua` 摘要漂移，CI 首个触发点为 `clangd_observation_spec.lua:111`）按契约回退上游英文（无崩溃、无数据污染）。[nightly CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44854071613/job/136691987989) |

### P1 性能同机复测

前后对照使用同机 `/usr/bin/nvim` 0.12.6、相同已验收 SDK 1 附件（`clang 0.1.0`、`clangd 0.1.2`）和隔离 XDG。启停组各重复 3 轮（每轮 30 次 1,000 条诊断刷新、50 次 500 项补全），CLI 3 轮各 12 次。原始样本见 `/tmp/nvim-zh-evolution.rerun/performance.json`。

| 负载 | 基线（`da04760`） | 当前工作树 | 变化 / 预算 |
| --- | ---: | ---: | --- |
| 两包冷启动（首次主快照） | 592.98 ms | 264.18 ms | -55.4% |
| 两包启动（五进程复用中位数 / 最大值） | 354.56 / 364.97 ms | 55.86 / 57.17 ms | -84.2%（预算 ≤287 ms，PASS） |
| 两包启动后 GC 后 RSS / Lua 堆 | 72.73 / 23.58 MiB | 20.73 / 1.80 MiB | -71.5% / -92.4%（PASS） |
| 无包 / 仅 clangd 启动中位数 | 54.65 / 201.89 ms | 54.75 / 56.44 ms | +0.2% / -72.0% |
| 启用 Clang，3,001 项列表打开 P50 / P95 | 3.70 / 7.50 ms | 0.59 / 0.73 ms | -90.3% P95（预算 ≤15 ms，PASS） |
| 关闭 Clang，3,001 项列表打开 P50 / P95 | 0.36 / 0.40 ms | 0.35 / 0.42 ms | 基线对照 |
| 1,000 条诊断虚拟文本（启用 P50 / P95） | 10.11 / 52.08 ms | 6.05 / 24.97 ms | -52.1% P95（预算 ≥25%，PASS） |
| 1,000 条诊断 quickfix（启用 P50 / P95） | 7.41 / 45.14 ms | 5.03 / 14.85 ms | -67.1% P95（预算 ≥25%，PASS） |
| 1,000 条诊断 loclist（启用 P50 / P95） | 7.70 / 40.52 ms | 5.20 / 23.70 ms | -41.5% P95（预算 ≥25%，PASS） |
| 500 项原生补全（启用 P50 / P95） | 1.77 / 12.79 ms | 1.33 / 8.75 ms | -31.6% P95 |
| `make check-translations`（3 次中位数） | 13.6 s（设计基线） | 2.39 s（2.33–2.43 s） | -82.4%（预算 ≤10.88 s，PASS） |

诊断关闭时三类入口 P95 为基线 11.05 / 5.05 / 1.07 ms 对工作树 3.91 / 1.48 / 1.60 ms。

### 首用量化与 P2 触发判断

- **首用实测（同机复测）：** 显式首查 `clang_get` / `clangd_get` 由 26.14 / 38.51 ms 变为 126.76 / 129.63 ms（首次模板匹配 5.98→6.45 ms、5.54→6.20 ms）；首个单错误 Clang 构建主线程返回由 97.04 ms 降至 16.42 ms（-83.1%），中文就绪由 98.70 ms 变为 150.21 ms；真实 clangd 5 次连接至中文诊断可见中位数（`after_attach_ms`）由 44.11 ms 变为 140.23 ms（`visible_ms` 57.78→154.11 ms）。计入启动后，端到端总耗时整体下降（`setup + clangd_get` 393.1→185.5 ms，-52.8%；`setup + clangd 可见` 246.0→196.6 ms，-20.1%）。
- **耗时与内存分解（单 9 MB 工具包）：** `store.load` 约 87 ms（其中 2 次 SHA-256 占 30–35 ms、外层+内层 2 次 JSON 解码占 29–34 ms、`prepare_sources` 校验占 9 ms、2 次磁盘读取共 18 MB 占 7–9 ms、`fs.utf8` 占 6 ms），`catalog.build` 占 37–39 ms。两域全部载入后 Lua 堆 60.44 MiB（基线 60.50 MiB）、RSS 85.24 MiB（基线 87.93 MiB）；`clang` 中 `diagnostic`+`note` 占 98.8%（33,124/33,543），`clangd` 中 `diagnostic`+`related_diagnostic` 占 99.2%（32,742/33,016），仅释出原始 `src` 表约省 5.5 MiB/域。
- **P2 判断：本轮不启动 P2。** P1 全部五项设计预算均已达标，延迟准备与准备中/取消/换代回退均已验证；在 SDK 1 现行单 JSON 封装内按 context 拆分加载无法绕过 87 ms 附件校验/双解码且覆盖面达 99%，而消除重复校验与解码属于新发布格式（SDK 2）决策范畴，留待后续独立版本决策。

### P1 构建与范围

生成入口已切换至 `translations/toolchain/zh_CN.json` 与固定 LLVM 输入。盘点、英文模板展开和双语分支选择使用同一解析结构。归并了 573 条独立译文与 10 条仅补充参考出处的记录。旧的 PO 回读合并和独立 clangd 盘点入口已移除。

LLVM 23.1.4 `7a941dfb` 与 23.1.5 `392dfff9` 的相邻基线双次复现、二进制/源码摘要拒写和历史 clangd 0.1.0/0.1.1 重建记录位于 `/tmp/nvim-zh-generation.9WcV8h`（2026-11-20）。本轮（2026-11-21）在当前工作树上再次双次生成三份正式 SDK 1 附件并逐字节比对，摘要与 `origin/packs@a7c9bab` 完全一致：`clang 0.1.0`（`ccaeb17c...`）、`clang-tidy 0.1.0`（`91eb1d39...`）、`clangd 0.1.2`（`0dd6344f...`）。SDK 1 和现行 JSON 继续作为交付基线。23.1.4 的证据仅用于生成再现，未扩大运行时支持。

### 门禁结果（2026-11-21，官方 Neovim 0.12.6）

| 检查 | 结果 |
| --- | --- |
| `make check-syntax check-translations check-native check-resources check-reproducible test release-check` | PASS（55 Python / 10 Shell / 121 Lua 语法通过，65 个 Lua 规格与 120 个 Python 用例通过，发布候选 590 个文件，`/tmp/nvim-zh-final-verify/gates.log`）。 |
| 离线 `make sync` | PASS（`SYNC_STATUS=OK changes=0 network=false`，`sync.log`）。 |
| 真实 native runtime 与真实 clangd（`NVIM_ZH_TEST_NATIVE_RUNTIME=1 NVIM_ZH_TEST_CLANGD=/usr/bin/clangd`） | PASS（项目 MO 探针与欢迎页通过；系统 locale MO 探针因官方压缩包缺 `share/locale/zh_CN.UTF-8/LC_MESSAGES/nvim.mo` 记 SKIP；15 样例 21 条 push 诊断原数据不变，真实 clangd 对 pull 返回 `-32601`，成功 pull 由独立契约覆盖，`real-native-clangd.log`）。 |
| 固定第三方上游矩阵（`make test-upstream`） | PASS（67/67 项全通过，`upstream.json`）。 |
| SDK 1 附件双次复现 + `toolchain_observe.py` + `clang_toolchain.py` + `toolchain_coverage.py --require-complete` | PASS（48 次驱动调用，602 个 clang-tidy 检查零缺口，真实 PTY 启停对照通过，91,654 样本零缺译/零歧义/零证据缺口，`TOOLCHAIN_COMPLETE=PASS`）。 |
| C++/DAP 终端（`tests/workflows/cpp_tui.py`）与 Python/Git 终端（`tests/workflows/python_git_tui.py`） | PASS（启停两组跳转位置、修复、构建退出码 2→0、CodeLLDB 调试退出码 0、pytest/Ruff/Git 冲突解决完全一致，`cpp-tui.log`、`python-git-tui.log`）。 |
| GitHub Actions CI（`c967a7c`：`platform.yml` 与 `test.yml`） | PASS（macOS 15.8.2 arm64 `localization.lua` 与 `packs.lua` 全通过；Ubuntu `offline (v0.12.6)` 全门禁 590 文件与 `upstream-smoke` 固定矩阵全通过；实验性 `offline (nightly)` 符合上述 0.12.6 runtime 接缝漂移预警）。[platform CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44854071678) · [test CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44854071613) |

## Clang 工具链完整覆盖验收（2026-11-20）

固定组合为官方 Neovim 0.12.6 Linux x86_64、LuaJIT 2.1.1774638290、glibc 2.44 和 WSL2，配合 Arch Linux `clang 23.1.5-1`。LLVM 源码固定到 `llvmorg-23.1.5`（commit `392dfff97d29b59d77e5cac6d4b6ef2585fe7117`）。完整运行证据位于 `/home/hanna/desktop/clang-toolchain-research/nvim-zh-run/complete-20261120-204356`。

| 命令或场景 | 本轮结果 | 证据 |
| --- | --- | --- |
| 词库同步与术语/校验 `tools/toolchain_catalog.py sync`、`tools/catalog_tool.py check` | PASS。10 个域共 70,587 条目零错误：Clang `33,543` 条、clangd `33,016` 条、clang-tidy `3,103` 条。展开 `1,599` 条多分支 TableGen 摘要、`20` 条 `%sub` 宏并核对 `131` 个已启用分析器检查（`116` 个输出诊断共 `1,715` 条源码核对消息、`15` 个纯建模检查）。 | [analyzer_audit.json](../translations/toolchain/analyzer_audit.json)、[zh_CN.json](../translations/toolchain/zh_CN.json) |
| 三个候选附件重复构建与 SHA-256 验证（`tools/pack_assets.py`） | PASS。`clang`（0.1.0，`ccaeb17c...`）、`clang-tidy`（0.1.0，`91eb1d39...`）、`clangd`（0.1.2，`0dd6344f...`）及 `catalog.json`（`3ac8a8ad...`）两次构建逐字节一致。 | `candidates/`、`candidates.sha256`、`candidates-2.sha256` |
| `python3 -B tools/toolchain_observe.py --output "$evidence/compiler.json"` | PASS。两个驱动运行 C/C++ 共 48 次（含成功、失败、含错与回退），`clang-tidy` 列出 602 个检查与清单一致（`registration_gaps=0`）；CLI 命中 172 条 + 20 条 clang-tidy，保留 14 条项目原文、8 条修复编辑、2 条子工具输出。 | `compiler.json` |
| `NVIM_ZH_TEST_CLANGD=/usr/bin/clangd NVIM_ZH_CLANGD_RECORD="$evidence/clangd.json" make test-contract test-integration` | PASS。15 样例 21 条 push 诊断主/说明命中 30 条 + 1 条 `#error` 原文；`clangd` 对 `textDocument/diagnostic`、`workspace/diagnostic`、`completionItem/resolve` 均返回 `-32601`，独立契约验证三项成功响应；真实编辑器及 LSP 处理器测试通过。 | `clangd.json`、`contracts.log` |
| `python3 -B tests/workflows/clang_toolchain.py --assets "$evidence/candidates" --evidence "$evidence/tui"` | PASS。同一中文路径 C/C++ 项目在官方 Neovim 0.12.6 真实 PTY 中导入候选附件对照：17 次命令、输出、解析项、退出状态、最终文件、附件摘要与 10 种协议消息一致；`tui_push` 命中 14 + 10 条、保留 2 条碰撞原文。 | `tui.log`、`tui/comparison.json`、两组 `wire.json`、屏幕文本及 `terminal.pty` |
| `python3 -B tools/toolchain_coverage.py … --require-complete` | PASS（退出码 `0`，`TOOLCHAIN_COMPLETE=PASS`）。Clang 合成命中 `44,693`（`matched_source_ids=7,261`，`31` 预期原文）、clangd 合成命中 `43,541`（`matched_source_ids=6,652`，`12` 预期原文）、clang-tidy 合成命中 `3,104`（`matched_source_ids=587`）。`0` 缺译、`0` 歧义、`evidence_gaps=[]`、`enabled_analyzer_audit_gaps=0`。 | `coverage.json`、`coverage.log` |
| `tests/workflows/clang_pack_official.lua` 与本地候选生命周期 | PASS。官方源 `clangd` 在线安装 0.1.0、升级 0.1.1、暂停/恢复、断网回滚、损坏恢复全部通过；`clang`（0.1.0→0.1.1）、`clang-tidy`（0.1.0→0.1.1）、`clangd`（0.1.1→0.1.2）离线导入、更新、损坏包拒绝、暂停/恢复和离线回滚全部通过。 | `official/`、`local-lifecycle/probe.log` |
| `NVIM_ZH_ADAPTER_SOURCE_ROOT=… make test-upstream` 及全量离线与发布门禁 | PASS。固定上游全矩阵（`nvim-cmp`、`nvim-dap`、`nvim-dap-ui`、`nvim-dap-view`、`nvim-tree`、`telescope`、`which-key`、`lazy.nvim`）及全套语法、资源包、单元测试、发布包检查通过。 | `upstream.json`、`upstream.log`、`gates.log` |

候选附件当前保存于本地证据目录，待明确发布授权后再行打 tag、发布 Release、更新官方目录与公开下载校验。其余 LLVM 版本、macOS、Windows、Neovim nightly 尚未纳入本轮实测。

## 上轮 Clang 工具链固定组合（2026-11-20）

使用官方 Neovim 0.12.6 Linux x86_64、glibc 2.44、LuaJIT 2.1.1774638290，配合 Arch Linux `clang 23.1.5-1`，在 WSL2 运行。证据目录为 `/home/hanna/desktop/clang-toolchain-research/nvim-zh-run`。完整二进制摘要与 LLVM 版本见[工具链清单](../manifests/toolchain.json)，复跑命令见[覆盖清单](toolchain-coverage.md)。

| 命令或场景 | 当次结果 | 证据 |
| --- | --- | --- |
| `python3 -B tools/toolchain_observe.py --output "$evidence/compiler.json"` | PASS。两个驱动均编译 C 和 C++。共 28 次驱动调用，覆盖成功、失败、头文件、语法、模板、约束、ABI 和 GNU ld 输出。Lua 复验 70 条诊断译文，保留 8 条项目原文、8 条修复编辑、2 条链接器消息。2 条包含栈前导仍为英文。 | `compiler.json`、`coverage-final.json` |
| 独立 clang-tidy | PASS。实际枚举 602 个检查名，样例输出 11 项命中，包括对应检查的附加说明和应用修复提示。导出 YAML 后实跑 `--fix`，再运行同一检查确认诊断清空。 | `compiler.json` 中的 `enabled_checks`、`clang_tidy`、`fix` |
| `NVIM_ZH_TEST_NATIVE_RUNTIME=1 NVIM_ZH_TEST_CLANGD=/usr/bin/clangd make test` | PASS。62 个 Lua 规格、117 个 Python 用例，Help 核对 133 篇。真实 clangd 向 15 个文件发布 21 条诊断，20 条显示匹配。历史独立契约验证成功 pull，真实进程对该请求返回 `-32601`。官方压缩包的系统 locale/MO 基线探针报告 SKIP，使用项目 MO 的独立探针通过。 | `gates-final.log`、`clangd-final.json` |
| `python3 -B tests/workflows/clang_toolchain.py --evidence "$evidence/tui-forwarded-fix"` | PASS。两组在中文目录导入三个候选包，打开 Help，并验证编译和跳转、已打开列表的刷新、位置列表注释、代码修复、悬浮、原生补全、签名、索引、文件状态、实际 AST 通知、clang-tidy 独立检查和转发、未知版本及原文碰撞。独立命令与转发代码动作各修复一份来源相同的样例，并通过各自的复查。两组的编译命令、原始输出、已解析项、退出状态和最终源码一致。八类请求和响应在归一化项目路径后逐项一致。异步进度帧数量及 AST 内存地址允许变化，未归一化记录保存在仓库外。 | `tui-forwarded-fix.log`、`tui-forwarded-fix/comparison.json`、两组 `wire.json`、`terminal.pty` 和屏幕文本 |
| `tests/workflows/clang_pack_official.lua` | PASS。在线从官方目录安装 clangd 0.1.0，更新至 0.1.1，暂停和恢复。禁用下载后从 0.1.1 回滚。在独立副本中损坏选定附件，重启加载已校验的 0.1.0，回滚后恢复登记。 | `official-final/online.log`、`offline.log`、`damaged.log` |
| `make check-syntax check-translations check-native build-resources check-resources check-reproducible test-upstream release-check sync` | PASS。固定上游契约和 TUI 矩阵通过。两次源码清单重建摘要一致。候选附件与候选索引在本地重复生成，旧索引条目均保留。 | `gates-final.log`、`build-final.log`、`upstream.log`、`upstream.json`、`release-check-final.log`、`inventory-repro.log`、`release-candidates.sha256` |
| `python3 -B tools/toolchain_coverage.py … --require-complete` | FAIL。Clang 合成命中 916 条，另有 43,726 条缺译和 50 条歧义。clangd 合成命中 835 条，42,707 条未命中。clang-tidy 合成命中 12 条，1,141 条未命中。完整覆盖门禁仍有 87,626 项未达标。 | `coverage-final.log`、`coverage-final.json` |

真实服务器也对 `workspace/diagnostic` 和 `completionItem/resolve` 返回 `-32601`。 `window/showMessage` 以 AST 通知验证项目内容原样显示。`window/showMessageRequest` 为源码核对和独立契约，暂无该服务器的真实请求。未知 CLI 版本使用报告 99.1.0 的测试入口，clangd 未知版本由独立编辑器探针注入。两者均核查原文回退。

当前附件为本地候选。固定范围仍有未翻译、未解析和未实测的项。源码分支可达性、依赖头文件的复杂预处理重映射、静态分析器的路径说明及其他工具/平台组合仍需补证。以下章节记录历史验收。

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
| 核心 Help | 固定 0.12.6 的 133 篇全量结构契约通过。逐篇使用 `:help <文件名>@cn` 和 `:help <文件名>@en` 打开，中文和英文各 133 篇。按清单的 10 个主题逐批抽查对齐段落，机器核对了 164 个可配对的字面默认值。修订 `starting` 的日志路径、`usr_24` 的删除位置和 `usr_25` 的实际插入换行。另用 `:set complete? matchtime? textwidth? wrap? startofline? shellpipe?` 验证关键默认值，修正 `usr_24` 对 `#include` 补全的说明。语义审阅覆盖样本与所修主题，其他段落仍需全文审校。 |
| 平台 | 在隔离环境执行 `nvim --headless -u NONE -i NONE -n -l tests/platform/localization.lua`。Windows 11 x86_64 和 macOS 15.8.2 arm64 使用官方 0.12.6，Alpine edge x86_64 使用 Neovim 0.12.2-r1 与 musl 1.2.6。三组通过中文 Help、英文 Help 回退、Lua UI 和原文通知回退。三组的原生后端均报告 `unsupported`，E482 保留英文。macOS 首次因系统目录别名拒绝了快照路径，修复后从系统别名路径复跑通过。[macOS CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44676795841) |

工作流说明和复跑环境见[中文操作指南](workflows.md)与[测试文档](testing.md)。

主包开发分支的 `4031052` 通过固定版离线与上游 CI。clangd 0.1.1 附件从公开地址下载并校验了 71 106 字节和 SHA-256。官方目录 `620b4a2` 保留原七条记录与附件。新用户目录从 0.1.0 更新到 0.1.1，连接真实 clangd 后显示中文诊断。注入未知服务器版本时显示原文，LSP 对象一致。断网重启后从 0.1.1 回滚到 0.1.0。[固定版 CI](https://github.com/DerckHanna/nvim-zh/actions/runs/44676795889) [clangd 0.1.1](https://github.com/DerckHanna/nvim-zh/releases/tag/packs-clangd-v0.1.1) [更新后的目录](https://github.com/DerckHanna/nvim-zh/blob/620b4a2bd2d091f98038f5548dfc1ac6989b2eb9/catalog.json)

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
