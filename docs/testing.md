# 测试与质量门禁

产品基线为 Neovim 0.12+，固定对照为 0.12.6。维护环境使用 Python 3.12、GNU Make、Bash；重建核心 MO 需要 GNU gettext `msgfmt`。安装用户不需要这些维护工具。

## 功能分类与入口

| 入口 | 目录 | 责任 |
|---|---|---|
| `make test-unit` | `tests/unit/engine` | 精确目录、模板、缓存、缺失记录、隐私、fuzz |
| `make test-contract` | `tests/contract` | 公共 API/命令、配置、Help、UI、适配器所有权、诊断/LSP 与字节边界、仓库守卫 |
| `make test-tools` | `tests/tools` | PO/native/资源构建、原子写、安全发布、Help relay 与 inventory |
| `make test-integration` | `tests/integration` | 配置保存/回滚、真实 Neovim Help/诊断、资源状态、并发、native 与可选 clangd |
| `make test-e2e` | `tests/e2e` | 真实 PTY、只读 TUI、临时本地 Git 与 vim.pack、可选中文欢迎页 |
| `make test-upstream` | `tests/upstream` | 固定 which-key、Telescope、lazy、nvim-tree、cmp 公开接缝和源码摘要 |

默认 `make test` 顺序执行前五类，不访问网络、不要求第三方源码。真实终端和本地 Git/vim.pack 都是离线测试。`tests/fixtures` 保存输入与历史服务器观察；`tests/support` 保存共享断言及进程环境，不向产品发布 fixture 目录条目。

```bash
make check-syntax
make check-translations check-native
make build-resources check-resources
make check-reproducible
make test
make release-check
```

`check-syntax` 使用 Neovim `loadfile`、Python AST 与 `bash -n`，仅做语法检查，不是完整类型分析，不要求 luacheck/stylua。`check-reproducible` 重建并逐字节核对 PO → Lua、固定上游 → MO，以及完整资源包。资源构建只在维护端发生。

`release-check` 从工作树复制临时候选，仅排除自身 `.git`；所有其余文件都接受严格检查，包括未跟踪文件。校验器自身拒绝 `.agents`、`.codex`、`.aws`、日志、零字节文件、符号链接、缓存、研究源码和备份，不用 Git 忽略规则掩盖残留。

## 环境隔离

`tests/run/lib/env.sh` 是全部 runner 的公共环境：私有 `XDG_STATE_HOME`、`XDG_DATA_HOME`、`XDG_CONFIG_HOME`、`XDG_CACHE_HOME`、权限 0700 的 `XDG_RUNTIME_DIR`、显式 `NVIM_LOG_FILE` 和私有 TMP 根，设置 `PYTHONDONTWRITEBYTECODE=1`，EXIT trap 删除该次环境。每个 Lua spec 单独启动一个 `nvim --headless -u NONE -i NONE -n`，用例间另建独立 case 目录；Python 子进程继承这些边界。POSIX PTY 专用 import 留在 e2e 内。

并发测试有意让两个进程共享同一个临时数据目录，屏障后同时 setup，比较双方 active bundle ID、最终 `state.json.active` 与磁盘 manifest。不能仅凭两边各有资源就判为通过。vim.pack fixture commit 只写临时测试仓库，绝不提交工作项目或改用户安装。

日志、错误配置、校验失败通知是负向测试输入；只有断言与进程退出成功才记 PASS。根目录旧 0 字节 `nvim.log` 的来源未确证，不能据猜测写根因。

## 固定上游

上游 repository、完整 commit 与实际接缝文件 SHA-256 来自 `manifests/upstreams.json`；Plenary 的固定测试依赖放在同一 manifest 的 `test_dependencies` 中。CI 按该清单获取源码，再使用相同 Make 入口。源码可放在仓库外任意目录：

```bash
up=/absolute/path/to/fixed-upstreams
NVIM_ZH_TEST_WHICH_KEY="$up/which-key" \
NVIM_ZH_TEST_TELESCOPE="$up/telescope" \
NVIM_ZH_TEST_PLENARY="$up/plenary" \
NVIM_ZH_TEST_LAZY="$up/lazy" \
NVIM_ZH_TEST_NVIM_TREE="$up/nvim-tree" \
NVIM_ZH_TEST_NVIM_CMP="$up/nvim-cmp" \
make test-upstream
```

该显式入口缺任何固定源码必须 FAIL；源码摘要不匹配同样 FAIL。离线适配器 fixture 只证明结构和所有权，真实上游才证明该固定版本的交互流程，二者都不代表整个插件汉化率。

## 可选 native、clangd 与性能

```bash
NVIM_ZH_TEST_NATIVE_RUNTIME=1 make test-integration test-e2e
NVIM_ZH_TEST_CLANGD=/usr/sbin/clangd make test-integration
bash benchmarks/run.sh
```

native 真实消息探针使用复制到临时前缀的 Neovim、临时 locale 与临时 MO，检查 E482/E576/E136/E5005、原文豁免和欢迎页；不写系统 locale 或 MO。自动接线、opt-out、绑定/语言独立所有权、异步外部修改、两次恢复失败与重试也在 Lua 集成中检查。性能读数只描述当次环境，不形成稳定性能承诺。

真实 clangd 重新观察固定 C++ corpus，通过同一显示断言验证 push、quickfix、`user_data.lsp` 与原始协议不变。服务器若返回 pull `-32601`，报告“不支持”，不声称成功；独立成功 pull 控制验证原始英文可以通过，已译文本和非字符串必须失败。`NVIM_ZH_CLANGD_RECORD` 可指定仓库外记录路径；默认只在临时目录记录。

## PASS / FAIL / SKIP / BLOCKED

- PASS：实际执行且退出成功。
- FAIL：实际执行但断言、源码校验、构建或进程失败。
- SKIP：明确的平台、版本或可选能力不适用，必须打印条件。默认未启用的 native runtime/clangd 探针不算 PASS；显式开启后依赖错误不能变成成功。
- BLOCKED：环境、权限、网络或依赖阻止执行，应在验证报告说明。工具超时、探测失败或空输出不能伪装成版本 SKIP。

Help parity 只在 manifest 固定 runtime 上比较上游文本。其他 runtime 明确 SKIP 上游比较，但 tag/示例块/链接摘要、索引与术语的内部契约仍运行。版本自报固定基线却为 prerelease 或摘要不符时必须 FAIL。

CI 固定 0.12.6 必跑，nightly 仅实验性预警；没有在 GitHub 实际执行就不能写 CI 已通过。未验证平台见[兼容性](compatibility.md)，本次实际结果见[验证记录](verification.md)。

## 逐文件迁移记录

本表仅解释原文件去向，不提供旧路径、旧 API、旧命令或旧 Make 入口的兼容层。文件内原有有效断言迁移保留；废弃调用改为当前公共 API，fixture 数据从生产目录中移出。

| 原文件 | 当前去向 / 处理 |
|---|---|
| `tests/phase0/e1_native.sh` | tests/integration/native/locale_probe.sh |
| `tests/phase0/e2_help.lua` | tests/contract/nvim/help_mechanism_spec.lua |
| `tests/phase0/e4_ui_attach.lua` | tests/contract/nvim/ui_attach_spec.lua；计时 → `benchmarks/ui_attach.lua` |
| `tests/phase1/01_setup_spec.lua` | tests/contract/config/setup_spec.lua |
| `tests/phase1/02_commands_spec.lua` | tests/contract/commands/public_spec.lua |
| `tests/phase1/03_native_health_spec.lua` | tests/integration/native/health_spec.lua |
| `tests/phase1/04_docs_spec.lua` | tests/integration/help/selection_spec.lua |
| `tests/phase1/05_help_ownership_spec.lua` | tests/contract/help/ownership_spec.lua |
| `tests/phase1/06_help_dependency_spec.lua` | tests/contract/help/dependency_spec.lua |
| `tests/phase10/01_config_spec.lua` | tests/integration/config/hot_config_spec.lua |
| `tests/phase10/02_native_spec.lua` | tests/integration/native/auto_spec.lua |
| `tests/phase10/03_resources_spec.lua` | tests/integration/resources/snapshot_spec.lua |
| `tests/phase10/04_lifecycle_spec.lua` | tests/integration/runtime/lifecycle_spec.lua |
| `tests/phase10/05_native_ownership_spec.lua` | tests/integration/native/ownership_spec.lua |
| `tests/phase10/06_async_native_ownership_spec.lua` | tests/integration/native/async_ownership_spec.lua |
| `tests/phase10/test_integration.py` | tests/e2e/test_pack_tui.py；公共基类 → `tests/support/process_case.py`；并发/初始损坏清单 → `tests/integration/resources/test_concurrency.py`、`test_initial_manifest.py`；PO/实现标识构建 → `tests/tools/test_resource_bundle.py` |
| `tests/phase2/01_engine_spec.lua` | tests/unit/engine/translate_spec.lua |
| `tests/phase2/02_catalog_spec.lua` | tests/unit/engine/catalog_spec.lua |
| `tests/phase2/03_missing_spec.lua` | tests/unit/engine/missing_spec.lua |
| `tests/phase2/04_commands_spec.lua` | tests/contract/commands/catalog_queries_spec.lua；改为精确 façade、无隐式 setup、missing/refresh 查询和旧命令不存在断言 |
| `tests/phase2/05_fuzz_perf_spec.lua` | tests/unit/engine/fuzz_cache_spec.lua |
| `tests/phase2/06_builtin_catalog_spec.lua` | tests/contract/catalog/builtin_spec.lua |
| `tests/phase2/07_runtime_regression_spec.lua` | tests/unit/engine/regression_spec.lua |
| `tests/phase2/08_catalog_reload_spec.lua` | tests/integration/catalog/refresh_spec.lua |
| `tests/phase2/09_path_privacy_spec.lua` | tests/unit/engine/path_privacy_spec.lua |
| `tests/phase2/test_catalog_tool.py` | tests/tools/test_catalog_tool.py |
| `tests/phase3/01_notify_spec.lua` | tests/contract/ui/notify_spec.lua |
| `tests/phase3/02_ui_callback_spec.lua` | tests/contract/ui/ui_callback_spec.lua |
| `tests/phase3/03_echo_spec.lua` | tests/contract/ui/echo_spec.lua |
| `tests/phase3/04_lifecycle_spec.lua` | tests/contract/ui/lifecycle_spec.lua |
| `tests/phase3/05_select_items_spec.lua` | tests/contract/ui/select_items_spec.lua |
| `tests/phase3/06_fuzz_perf_spec.lua` | tests/contract/ui/fuzz_perf_spec.lua |
| `tests/phase3/07_integration_spec.lua` | tests/integration/ui/integration_spec.lua |
| `tests/phase3/08_wrapper_chain_spec.lua` | tests/contract/ui/wrapper_chain_spec.lua |
| `tests/phase3/09_negative_spec.lua` | tests/contract/ui/negative_spec.lua |
| `tests/phase3/10_differential_spec.lua` | tests/contract/ui/differential_spec.lua |
| `tests/phase3/11_retained_items_spec.lua` | tests/contract/ui/retained_items_spec.lua |
| `tests/phase3/12_notify_source_spec.lua` | tests/contract/ui/notify_source_spec.lua |
| `tests/phase3/helpers.lua` | tests/support/ui_helpers.lua |
| `tests/phase4/01_which_key_spec.lua` | tests/contract/plugins/which_key_spec.lua |
| `tests/phase4/02_telescope_spec.lua` | tests/contract/plugins/telescope_spec.lua |
| `tests/phase4/03_lifecycle_spec.lua` | tests/contract/plugins/lifecycle_spec.lua |
| `tests/phase4/04_differential_spec.lua` | tests/contract/plugins/differential_spec.lua |
| `tests/phase4/05_upstream_smoke_spec.lua` | tests/upstream/upstream_smoke_spec.lua |
| `tests/phase4/06_integration_spec.lua` | tests/contract/plugins/integration_spec.lua |
| `tests/phase4/07_lazy_late_load_spec.lua` | tests/contract/plugins/lazy_late_load_spec.lua |
| `tests/phase4/08_telescope_dynamic_spec.lua` | tests/contract/plugins/telescope_dynamic_spec.lua |
| `tests/phase4/09_nvim_tree_spec.lua` | tests/contract/plugins/nvim_tree_spec.lua |
| `tests/phase4/10_additional_upstream_smoke_spec.lua` | tests/upstream/additional_upstream_smoke_spec.lua |
| `tests/phase4/11_retained_tree_spec.lua` | tests/contract/plugins/retained_tree_spec.lua |
| `tests/phase4/12_which_key_upstream_spec.lua` | tests/upstream/which_key_upstream_spec.lua |
| `tests/phase4/helpers.lua` | tests/support/plugin_helpers.lua |
| `tests/phase4/test_upstream_sources.py` | tests/upstream/test_sources.py |
| `tests/phase5/01_diagnostic_display_spec.lua` | tests/contract/diagnostics/diagnostic_display_spec.lua |
| `tests/phase5/02_push_pull_spec.lua` | tests/integration/diagnostics/push_pull_spec.lua |
| `tests/phase5/03_lsp_handlers_spec.lua` | tests/contract/lsp/lsp_handlers_spec.lua |
| `tests/phase5/04_external_tool_spec.lua` | tests/contract/boundaries/external_tool_spec.lua；删除同文件读写前后的自比较，改为真实子进程 NUL/非 UTF-8 与 shell 字节断言，保留 system 不包装断言 |
| `tests/phase5/05_differential_perf_spec.lua` | tests/contract/diagnostics/differential_perf_spec.lua |
| `tests/phase5/06_async_request_spec.lua` | tests/integration/diagnostics/async_request_spec.lua |
| `tests/phase5/07_runtime_regression_spec.lua` | tests/integration/diagnostics/runtime_regression_spec.lua |
| `tests/phase5/08_formatter_contract_spec.lua` | tests/contract/diagnostics/formatter_contract_spec.lua |
| `tests/phase5/fixtures/clangd-corpus.json` | tests/fixtures/clangd/messages.json |
| `tests/phase5/fixtures/external-tool.json` | 删除：未执行产品逻辑的字节自比较 fixture；由真实子进程断言替代 |
| `tests/phase5/helpers.lua` | tests/support/diagnostic_helpers.lua |
| `tests/phase6/fixtures/sync-change.json` | tests/fixtures/catalog/sync-change.json |
| `tests/phase6/test_catalog_safety.py` | tests/tools/test_catalog_safety.py |
| `tests/phase6/test_help_relay.py` | tests/tools/test_help_relay.py |
| `tests/phase6/test_maintenance.py` | tests/contract/repository/test_maintenance.py |
| `tests/phase7/01_clangd_extension_spec.lua` | tests/contract/diagnostics/clangd_templates_spec.lua；fixture 计数改为生产 inventory 与不发布伪覆盖率断言，保留模板、formatter、回退契约 |
| `tests/phase7/02_observed_diagnostic_contract_spec.lua` | tests/contract/diagnostics/clangd_observation_spec.lua |
| `tests/phase7/corpus/expected_semicolon.cpp` | tests/fixtures/clangd/corpus/expected_semicolon.cpp |
| `tests/phase7/corpus/redefinition.cpp` | tests/fixtures/clangd/corpus/redefinition.cpp |
| `tests/phase7/corpus/undeclared.cpp` | tests/fixtures/clangd/corpus/undeclared.cpp |
| `tests/phase7/corpus/unknown_type.cpp` | tests/fixtures/clangd/corpus/unknown_type.cpp |
| `tests/phase7/fixtures/clangd-real-observed.json` | tests/fixtures/clangd/observed.json |
| `tests/phase7/helpers.lua` | tests/support/clangd_helpers.lua |
| `tests/phase7/public_seam_smoke.py` | tests/upstream/cmp_seam.py |
| `tests/phase7/real_clangd_smoke.py` | tests/integration/clangd/real_smoke.py |
| `tests/phase7/test_smoke_infrastructure.py` | tests/integration/clangd/test_harness.py |
| `tests/phase8/01_help_catalog_spec.lua` | tests/contract/help/catalog_spec.lua |
| `tests/phase8/02_lsp_ui_text_spec.lua` | tests/integration/nvim/lsp_literals_spec.lua |
| `tests/phase8/03_help_parity_rules_spec.lua` | tests/contract/help/parity_rules_spec.lua |
| `tests/phase8/check_help_parity.py` | tools/help_parity.py |
| `tests/phase8/test_help_catalog.py` | tests/integration/help/test_tags.py |
| `tests/phase8/test_help_inventory.py` | tests/tools/test_help_inventory.py |
| `tests/phase8/test_help_parity_skip.py` | tests/integration/help/test_parity_classification.py |
| `tests/phase8/test_help_terminology.py` | tests/contract/help/test_terminology.py |
| `tests/phase9/test_intro_catalog.py` | tests/tools/test_intro_catalog.py；PTY 欢迎页 → `tests/e2e/native/test_intro.py` |
| `tests/phase9/test_native_catalog.py` | tests/tools/test_native_catalog.py；真实消息类 → `tests/integration/native/test_messages.py`，平台探针 → `tests/support/native_probe.py` |
| `tests/phase0/README.md` | 删除：研究阶段说明，改由本文件记录维护与执行方式。 |
| `tests/phase0/e3_public_ui.lua` | 删除：手写包装原型，实际 UI/diagnostics 契约已覆盖；不属于产品实现。 |
| `tests/phase0/e5_diagnostic.lua` | 删除：手写包装原型，实际 UI/diagnostics 契约已覆盖；不属于产品实现。 |
| `tests/phase0/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase1/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase10/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase2/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase3/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase4/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase5/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase7/foundation.sh` | 删除：产品统一要求 0.12+，删除旧版本子集入口。 |
| `tests/phase7/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase8/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |
| `tests/phase9/run.sh` | 删除：由 tests/run/ 的功能 runner 替代；断言逐项迁移。 |

新增回归：`integration/native/restore_spec.lua` 检查恢复顺序、`restore_failed` 与重试；clangd harness 增加成功 pull 正负控制；并发断言发现并修复目录创建竞争。`support/public.lua` 仅等待当前 `refresh(callback)` 完成，不模拟旧 API。

Help parity 引擎是移动到 `tools/help_parity.py` 的原实现，未复制另一套；relay/inventory 均保留其 `parity` 模块别名供故障注入。PO source refs、工具说明与 inventory 生成说明同步改为功能路径，生成 Lua 与 resources 由工具重建。
