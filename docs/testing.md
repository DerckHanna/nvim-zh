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
| `make test-upstream` | `tests/upstream` | 固定 which-key、Telescope、lazy、nvim-tree、cmp、nvim-dap、nvim-dap-ui 的公开或固定显示接缝与源码摘要 |

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

`release-check` 从工作树复制临时候选，排除自身 `.git` 和工作环境创建的空 `.agents`、`.codex`、`.aws` 挂载目录。其余文件均接受严格检查，包括未跟踪文件。校验器自身拒绝 `.agents`、`.codex`、`.aws`、日志、零字节文件、符号链接、缓存、研究源码和备份，不用 Git 忽略规则掩盖残留。

## 环境隔离

`tests/run/lib/env.sh` 是全部 runner 的公共环境：私有 `XDG_STATE_HOME`、`XDG_DATA_HOME`、`XDG_CONFIG_HOME`、`XDG_CACHE_HOME`、权限 0700 的 `XDG_RUNTIME_DIR`、显式 `NVIM_LOG_FILE` 和私有 TMP 根，设置 `PYTHONDONTWRITEBYTECODE=1`，EXIT trap 删除该次环境。每个 Lua spec 单独启动一个 `nvim --headless -u NONE -i NONE -n`，用例间另建独立 case 目录；Python 子进程继承这些边界。POSIX PTY 专用 import 留在 e2e 内。

并发测试有意让两个进程共享同一个临时数据目录，屏障后同时 setup，比较双方 active bundle ID、最终 `state.json.active` 与磁盘 manifest。不能仅凭两边各有资源就判为通过。vim.pack fixture commit 只写临时测试仓库，绝不提交工作项目或改用户安装。

日志、错误配置、校验失败通知是负向测试输入；只有断言与进程退出成功才记 PASS。根目录旧 0 字节 `nvim.log` 的来源未确证，不能据猜测写根因。

## 固定上游

每个插件的组合来自 `manifests/adapters/`，测试源码目录按 `<id>/<commit>` 存放。真实 TUI 使用 POSIX PTY、C 编译器和 libvterm 开发头文件。CI 安装相同依赖并运行同一入口。

```bash
up=/absolute/path/to/fixed-upstreams
python3 -B tools/adapter_tool.py lock all --json > /tmp/nvim-zh-adapter-lock.json
python3 -B tools/adapter_tool.py fetch --lock /tmp/nvim-zh-adapter-lock.json --source-root "$up"
NVIM_ZH_ADAPTER_SOURCE_ROOT="$up" make test-upstream
```

`fetch` 是显式联网入口。测试读取本地检出并校验源码摘要。需要保留机读证据时，将 `NVIM_ZH_ADAPTER_REPORT` 指向要保存的 JSON 文件。单适配器的 `test <id> --upstream --target baseline --source-root "$up"` 运行该组合的全部真实终端场景。缺失源码、摘要不符、PTY 环境不可用或屏幕断言失败均返回非零退出码。离线契约使用 `test <id> --offline` 单独运行。覆盖与候选审计详见[适配系统设计](adapter-system-design.md)。

可选 GDB 终端探针要求 C 编译器、支持 DAP 的 GDB 和跟踪其子进程的权限。用与清单一致的三个固定源码目录运行。

```bash
source tests/run/lib/env.sh
export NVIM_ZH_TEST_NVIM_DAP=/absolute/path/to/fixed/nvim-dap
export NVIM_ZH_TEST_NVIM_DAP_UI=/absolute/path/to/fixed/nvim-dap-ui
export NVIM_ZH_TEST_NVIM_NIO=/absolute/path/to/fixed/nvim-nio
python3 tests/upstream/nvim-dap-ui/gdb_tui.py gdb_session
```

探针编译并启动临时 C 程序，在条件断点处查看变量，单步后核对值，打开断点 quickfix，最后继续运行至会话退出。中文启停各执行一次。

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

测试重构前的路径对应关系见[迁移记录](archive/test-path-migration.md)。
