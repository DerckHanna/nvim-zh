# 测试路径迁移记录

[当前测试入口](../testing.md)

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
| `tests/phase1/06_help_dependency_spec.lua` | 随 Vimcdoc 健康检查选项移除 |
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
| `tests/phase4/01_which_key_spec.lua` | tests/contract/plugins/which-key/which_key_spec.lua |
| `tests/phase4/02_telescope_spec.lua` | tests/contract/plugins/telescope/telescope_spec.lua |
| `tests/phase4/03_lifecycle_spec.lua` | tests/contract/plugins/lifecycle_spec.lua |
| `tests/phase4/04_differential_spec.lua` | tests/contract/plugins/differential_spec.lua |
| `tests/phase4/05_upstream_smoke_spec.lua` | tests/upstream/telescope/upstream_smoke_spec.lua |
| `tests/phase4/06_integration_spec.lua` | tests/contract/plugins/integration_spec.lua |
| `tests/phase4/07_lazy_late_load_spec.lua` | tests/contract/plugins/which-key/lazy_late_load_spec.lua |
| `tests/phase4/08_telescope_dynamic_spec.lua` | tests/contract/plugins/telescope/telescope_dynamic_spec.lua |
| `tests/phase4/09_nvim_tree_spec.lua` | tests/contract/plugins/nvim-tree/nvim_tree_spec.lua |
| `tests/phase4/10_additional_upstream_smoke_spec.lua` | tests/upstream/nvim-tree/additional_upstream_smoke_spec.lua |
| `tests/phase4/11_retained_tree_spec.lua` | tests/contract/plugins/nvim-tree/retained_tree_spec.lua |
| `tests/phase4/12_which_key_upstream_spec.lua` | tests/upstream/which-key/which_key_upstream_spec.lua |
| `tests/phase4/helpers.lua` | tests/support/plugin_helpers.lua |
| `tests/phase4/test_upstream_sources.py` | 固定源码与 PO 引用由 `tools/adapter_tool.py` 校验，实际接缝由各插件的上游契约验证 |
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
| `tests/phase7/public_seam_smoke.py` | tests/upstream/nvim-cmp/cmp_seam.py |
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
