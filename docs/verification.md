# 本次验证记录

日期：2026-11-18。目录：`/home/hanna/desktop/nvim-zh`。分支 `main`、HEAD `b889fc1`；工作树在接手前已有未提交改动，本次未提交、推送、打 tag 或发布，也未操作用户安装、系统 Neovim/MO 或真实 Neovim 配置。

本记录只列本次实际执行结果，不继承旧报告的全绿结论。PASS 是实际退出成功；FAIL 是实际失败；SKIP 是明确可选/平台条件不适用；BLOCKED 是环境、权限、依赖或网络阻止执行。语法检查不等于完整类型分析。

## 环境

- Linux 6.18.58.1-microsoft-standard-WSL2，x86_64，GNU libc 2.44。
- Neovim v0.12.6，RelWithDebInfo，LuaJIT 2.1.1794386141。
- Python 3.12.15、GNU Make、Bash；msgfmt/msgunfmt（GNU gettext-tools）1.0。
- 真实 clangd：`/usr/sbin/clangd`，23.1.5；本机有 localedef 与 zh_CN locale source。
- 所有 runner 使用私有 XDG/日志/TMP 环境。临时 Git fixture commit 只存在于测试仓库。

## 迁移前定点复验

先执行 `git status --short` 与 `git diff --check`，未回退改动。修复 `nvim-ui.po` 的单个误字符后，三项资源命令实际通过，但第一次输出仍为 6 domains / 395 entries，暴露构建输入与运行时不一致。移除无生产调用方的 PO，统一从 `catalog.lua` 的 `BUILTIN_SOURCES` 派生生产输入后重建为 5 domains / 391 entries。

迁移前原核心、配置/资源和适配器 runner 实际通过：含 5 个 Python 集成用例、12 个适配 Lua 规格与固定上游源码检查 `files=52 plugins=5`。这些只记录起始状态；最终验收使用下列功能入口。

## 最终命令矩阵

| 命令 | 结果 | 实际范围 |
|---|---|---|
| `make check-syntax` | PASS | 30 Python、10 Shell、99 Lua 文件；AST / bash -n / loadfile |
| `make check-translations` | PASS | 5 个生产 domain、391 条；占位符、术语、受保护片段 |
| `make check-native` | PASS | 130 gaps、118 supplement、12 exemptions、4 repairs、25 prefix repairs、6 intro |
| `make build-resources` | PASS | 5 个生成 Lua；固定上游构建 MO；完整 145 文件资源包 |
| `make check-resources` | PASS | 缺失、陈旧、多余资源及符号链接检查 |
| `make check-reproducible` | PASS | 生成 Lua、固定上游重建 MO、完整 resources 逐字节一致 |
| `make test` | PASS | 五类离线套件：58 Lua 规格、106 个 Python 测试通过，3 个可选测试 SKIP；含真实 PTY 与本地 vim.pack |
| `make test-upstream`（下列六个固定目录变量） | PASS | which-key、Telescope、lazy、nvim-tree、cmp；52 接缝文件，另验 Plenary 固定测试依赖 |
| `NVIM_ZH_TEST_NATIVE_RUNTIME=1 make test-integration test-e2e` | PASS | 真实 MO 消息 2 项、真实中文欢迎页 1 项，以及完整集成/TUI/vim.pack |
| `NVIM_ZH_TEST_CLANGD=/usr/sbin/clangd make test-integration` | PASS | 实机 push 6/6、raw/quickfix/user_data.lsp 不变；成功 pull 正负控制 |
| 上游缺源码负控（清除六个变量后执行 `make test-upstream`） | PASS | 内层退出 2，明确 FAIL，未以 SKIP 退出成功 |
| `make sync` | PASS | `changes=0 network=false`，离线只读 |
| `bash benchmarks/run.sh` | PASS | UI attach 202 个事件，history/cmdheight 保留；200 次基线 0.248 ms、观察 0.250 ms，仅当次读数 |
| `make release-check`（获准在沙箱外执行） | PASS | 462 个候选文件；仅排除 .git，未忽略发布残留 |
| 最后 TMPDIR 收尾：catalog tool / Help relay / repository 三个 Python 测试文件 | PASS | 41 项通过；移除硬编码 /tmp，统一继承私有 TMP 根；语法再次通过 |
| `git diff --check` / `git status --short` | PASS | 无空白错误；保留未提交改动与测试迁移，未提交项目 |

固定上游实际调用设置：`NVIM_ZH_TEST_WHICH_KEY=$up/which-key`、`NVIM_ZH_TEST_TELESCOPE=$up/telescope`、`NVIM_ZH_TEST_PLENARY=$up/plenary`、`NVIM_ZH_TEST_LAZY=$up/lazy`、`NVIM_ZH_TEST_NVIM_TREE=$up/nvim-tree`、`NVIM_ZH_TEST_NVIM_CMP=$up/nvim-cmp`，其中当时 `$up=$PWD/.agents/refactor/upstreams`。完成实际验证后该临时缓存按要求清理；后续复跑按[测试文档](testing.md)在仓库外准备同一 manifest 固定源码。

## 负向契约与修复

- 配置保存、连续保存、错误 JSON/UTF-8、删除继承、数组整体替换、应用失败回滚均检查；查询和 headless 面板不隐式 setup/写资源。
- 真实 TUI 验证只读、28×10 窄终端、resize、关闭/重开与清理、无 UI 返回错误；观察统计和配置不被面板改动。
- 真实 vim.pack 验证重命名包、标准确认、取消、UI/Help/MO 同代更新、实现冻结、损坏资源保留与版本回退；只用本地临时 Git 仓库。
- 资源检查保留 checksum、缺 Help、MO 越界、未来 schema、符号链接、state 写失败与 PackChanged 损坏断言。
- 并发断言加强后曾 FAIL：两个全新进程竞争创建中间父目录，递归 mkdir 报 E739。修复为逐层创建并校验后，比较两个进程 active bundle ID、最终磁盘 state 和 manifest 同代通过；没有放宽断言。
- 原生 opt-out 恢复消息语言，gettext 绑定/语言独立所有权；localedef 异步成功和失败均不覆盖外部修改。新增故障注入证实先用原 LOCPATH、再暂清尝试系统 locale，两次失败报告 `restore_failed`、保留可重试状态，协调器也报告失败，恢复能力后重试成功。
- pending check 被取代时 `cancelled/superseded`；check/refresh teardown 时 `cancelled/stopped`。refresh 取消包含 error、task_id 与 restart_required。
- 外部 UI wrapper、diagnostic formatter、LSP handler 和插件函数的所有权在 disable/teardown 后重新启用仍不抢回；模块表换代单独验证。
- clangd 的原始 push/pull、quickfix、user_data.lsp 与协议对象保留；外部工具使用真实 NUL/非 UTF-8 子进程与 shell 字节控制，system 函数未包装。
- 修复陈旧测试：公共查询改用当前接口；目录统计改为 inventory；UI refresh 保持 owned wrapper 幂等；来源注册按实际 title/context 与增量校验；英文 Help fallback 用永久排除的 credits.txt。以上迁移期间曾 FAIL，均定位后修复，未恢复废弃 API。

负向配置、损坏资源与 native 注入日志中的预期错误通知，不等于断言失败。完整 Help parity 实测 `documents=133 problems=0`；这只证明结构契约，不表示逐句语义审校完成。

## SKIP、未验证与边界

- 默认离线 `make test` 中：2 个真实 native message 与 1 个 native 欢迎页测试因未设置 `NVIM_ZH_TEST_NATIVE_RUNTIME=1` 而 SKIP；真实 clangd 因未设置路径 SKIP。这些可选检查已通过上表显式调用另行验证，不把默认 SKIP 写成 PASS。
- clangd 23.1.5 对 `textDocument/diagnostic` 实际返回 `-32601`（method not found）；服务器 pull 记为不支持，未宣称成功。成功 pull 的原文/译文/非字符串正负控制实际执行通过。
- which-key `replace.desc` 无 provenance，自定义描述恰与内置 msgid 相同也可能显示同一译文；footer/私有 Buffer 保持英文。
- Telescope 内部英文行为标题保留；最终 refine 的 `border:change_title` 无安全接缝，未覆盖。nvim-tree 自定义 on_attach 描述、已有 Buffer 及私有 renderer 不改写。cmp 为 inventory-only。
- 未验证 Windows、macOS、musl、其他 Neovim 版本；GitHub 实际 CI、网络获取与发布均未执行。CI 配置已更新为固定 0.12.6 必跑、nightly 实验预警，但不能记录为 CI 已通过。
- 清单编辑状态、Help 结构契约、固定源码证据与真实运行时观察是不同概念；391 条目录与 fixture 命中率都不是整个产品的汉化率。

## 收尾与发布候选

清理前 `make release-check` 实际 FAIL：保留的临时上游/探针 `.agents/refactor`、原 0 字节 `nvim.log`，以及执行沙箱注入的只读空 `.codex`/`.aws` 挂载均被拒绝。这是有效门禁，不通过扩大排除规则或删除断言绕过。根日志的 mtime 为 2026-11-18 13:35:30 +0800，复验期间大小/mtime 未变，来源仍未确证。

固定上游真实测试完成后，临时研究目录和原日志先备份到仓库外 `/tmp/nvim-zh-refactor-evidence-20261118.tar`，再按授权删除工作树中的本次临时产物。发布规则仅排除 `.git`；环境注入的只读挂载若影响候选，需要在无该挂载的真实工作树执行同一发布命令，并如实记录权限/执行环境。

最终清理和发布检查在获得环境权限后执行：删除的绝对路径为 `/home/hanna/desktop/nvim-zh/.agents/refactor`，随后仅在父目录为空时 rmdir `.agents`；原日志已归档后删除。沙箱外同一 `make release-check` 实际退出 0，Lua/MO/完整资源可重复性与资源校验再次通过。沙箱注入的空元数据挂载未出现在真实候选中，未更改发布排除规则。该权限条件已解除，最终无 BLOCKED 项。

本地重构验收完成；当前有效用例无 FAIL。上表默认可选 SKIP 均另有显式实测，实机服务器 pull 不支持与未验证平台仍保留上述限制。仅项目自有 `doc/nvim-zh.cnx/.txt` 随接口调整，未批量改写上游 Help 译文。
