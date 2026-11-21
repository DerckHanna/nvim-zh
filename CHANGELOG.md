# Changelog

本项目遵循语义化版本。

## [0.3.0] - 2026-11-21

### 新增

- nvim-cmp 中文状态、配置弃用提示、自定义菜单默认类别和完整中文帮助。
- 状态面板按当前 Buffer 和各个 clangd 客户端显示文件状态及进度。

### 修复

- 按窗口和项目隔离 quickfix、location list 和编译器探测。按客户端、方法及 token 分别处理诊断与进度。
- 隔离 DAP 会话的 Scope 请求、渲染与 REPL 临时状态。浮窗标题保留用户自定义文本。
- 原生补全保留候选、编辑、回调和 resolve 数据。悬浮与签名使用有客户端来源证据的显示接缝。

### 变更

- 公开目录统一使用 SDK 2。七个插件包与三个 Clang 工具包发布独立的 `0.3.0` 版本，SDK 1 附件退出公开下载。
- SDK 2 安装与回滚继续校验附件摘要。插件入口或格式变化时，重启后一起切换实现和资源。

## [0.2.0] - 2026-11-21

### Added

- 在单一 `pack_store.lua` 验证边界内新增独立版本号 SDK 2 单层紧凑附件格式（支持 `tools/pack_assets.py --sdk 2`，纯数据包仅落盘 `artifact.json` 并在每次加载执行完整 SHA-256 与 UTF-8 校验）；候选 `0.2.0` 首用耗时降至 ~44 ms（-70%），并保留与已发布 SDK 1 的损坏回退、离线回滚及旧客户端 `sdk == 1` 自动兼容。
- 添加固定 LLVM 23.1.5 的 Clang 与 clang-tidy 汉化包、quickfix/location list 显示和原文查询。
- 增加 clangd 文件状态与 clang-tidy 转发诊断显示。工具身份、源码盘点、匹配记录和实际工作流详见 `docs/toolchain-coverage.md`。
- clangd 词库增加 LSP 服务器身份、版本和所用方法的兼容声明。C/C++ 状态显示回退原因。
- 增加中文 C/C++、pytest、Ruff 和 Git 冲突操作指南与实际终端对照。

### Changed

- 重构词库内存表示为按 `context` 两级索引与非破坏性 `overrides` 覆盖层，挂载后立即释放原始解码表，双域常驻 Lua 堆降低 71%（59.4→17.2 MiB）、RSS 降低 58%。
- 大工具词库按实际使用准备，编译器版本及摘要在后台验证。翻译检查与测试复用已解析输入和附件。工具链 PO 从单一编辑源生成，LLVM 23.1.4 与 23.1.5 均通过重复构建。
- 同步失败保留上一份有效配置和资源，取消回调在旧任务清理后交付。汉化包自动推荐需要目标兼容证据，历史版本仍可显式选择和离线回滚。

### Fixed

- 修复诊断 quickfix/location list 条目与 LSP 进度数据被翻译的问题。中文由列表和面板显示，列表查询、LspProgress、client.progress、fileStatus handler 和通用 LSP 回调保留上游数据。
- 修复 macOS 系统目录别名（`/var`、`/tmp`、`/etc`）路径下读取或导入汉化包被误判为符号链接的问题。
- 修复 12 个 Neovim 0.12.6 核心 gettext 键，补记 Windows、macOS 和 Linux/musl 回退验证。

## [0.1.0] - 2026-11-20

### Added

- `:NvimZh` 中文面板展示运行与安装版本、活动资源、翻译观察、脱敏缺失和健康检查。
- `:NvimZhPacks` 管理 clangd、which-key、Telescope、nvim-tree、nvim-dap、nvim-dap-ui 和 nvim-dap-view 的可选汉化资源。支持显式刷新官方目录、按需安装、更新、暂停、恢复、离线导入、回滚和卸载。
- 可选 `nvim-zh.json` 热配置，保存后自动校验并应用；坏配置保留上一份有效状态，删除文件恢复基础配置。
- 随包交付 MO、UI/诊断/LSP 目录、中文 Help 和预生成索引。vim.pack 确认更新后自动同步同一资源集，取消或候选损坏时保留旧集，包回退自动跟随。
- 当前会话冻结实现代码；纯资源更新直接生效，实现变化提示重启并在下次启动自动完成。
- 受支持 Linux/glibc + LuaJIT 环境自动绑定用户目录中的 MO，必要时异步准备私有 locale，不修改系统文件或子进程环境。
- `status()`、`stats()`、`missing()`、`open()`、`check()`、`refresh()` 结构化接口，以及 `translate()`、`register_catalog()`、`teardown()`。
- which-key 内置 preset/生成数量与通知、Telescope 初始及动态标题与通知、nvim-tree 默认映射与通知的固定上游适配。
- nvim-dap 的通知、结构化选择器、REPL 帮助、直接输入提示、quickfix/健康报告显示适配；nvim-dap-ui 的固定渲染文本、mapping 描述、浮窗标题、元素/Window 选择器与通知适配。两者均保留动态调试数据和原始协议行为。
- 精确通知 title 来源注册，保留插件前缀并避免公共 UI 二次翻译。
- 扩充 clangd 的 C++ 语法、类型、模板与警告译文，加入相关注释、诊断列表、代码操作、悬浮提示、原生补全和进度汉化。
- 按单元、公共契约、维护工具、集成、真实端到端和固定上游划分的测试入口，以及真实 PTY、vim.pack、native 和并发验证。

### Changed

- 公共入口、session、runtime、resources、native backend、status、health、TUI 和独立适配器按职责拆分；查询与渲染不再承担同步业务流程。
- Telescope 改为翻译初始标题显示投影，不再改写 picker 内部英文标题，保留 `to_fuzzy_refine` 行为。
- nvim-tree 覆盖默认 `on_attach` 和 lazy 先 setup 后 `LazyLoad` 的真实顺序，保留 `nvim-tree: ` 前缀及用户自定义描述。
- 外部函数替换与模块表换代分别处理；禁用、teardown 后重新启用也不抢回外部所有权。
- 静态统计只报告已加载目录条目数与本进程观察，不再把条目数包装成 100% 覆盖率；fixture 命中数不进入运行时能力指标。
- 最低支持版本统一为 Neovim 0.12+，安装和更新统一使用 vim.pack。
- README 精简为用户入口；配置、API、架构、适配、兼容性、测试和贡献流程分别维护，项目 Help 删除阶段性锚点。

### Removed

- 移除 `modules.help.vimcdoc` 和固定值 `terminology`。升级时从 Lua 与热配置删除这两个字段。

- 删除 `info()`、`show_info()`、`show_missing()`、`reload()` 及 `:NvimZhInfo`、`:NvimZhMissing`、`:NvimZhReload`；使用 `status()`、`missing()` 和 `refresh()`。
- `check()` / `refresh()` 改为直接接收可选 callback，不再保留无实际作用的 opts 参数；`open()` 同样不再接收空选项。
- 删除无生产调用方的 `nvim-zh` 内置 domain，以及 `Ready`、`Echo ready` 等只为早期 fixture 服务的交付条目；测试使用自己的目录或真实 Neovim 文本。
- 删除旧 `tests/phase*` 入口、手写原型测试、重复 fixture 自比较和 0.10 foundation 兼容入口。重要差分、负向、所有权、并发和真实交互契约迁往功能套件。
- 删除陈旧设计/实施进度叙述和未反映当次验证的通过宣传。历史兼容性声明不再替代当前验证。

### Fixed

- 使用普通 `vim.pack` 加载时自动记录固定上游模块的源码摘要；包更新后继续依据实际加载的模块代次决定能否投影。
- 隔离 which-key 与 Telescope 的健康报告翻译，修复同会话中互相覆盖。
- 修复 nvim-tree 中文帮助浮窗的显示列对齐，补齐浮窗映射说明及隐藏统计原因。
- 已格式化动态文本中的相邻占位符无法分离时安全回退，避免错配用户字段。

- 显式关闭原生接线时恢复原消息语言；原 LOCPATH 不可用时尝试系统 locale，最终失败明确报告 `restore_failed` 并保留重试状态。
- 原生启动或状态发布失败时补偿目录、Help、配置和资源状态，不再提交半套候选。
- 异步 locale 准备尊重外部 gettext 绑定和消息语言变化；pending check/refresh 在取代或 teardown 时明确取消。
- nvim-tree 默认映射原先完全绕过适配的问题，以及全角冒号破坏帮助页前缀解析的问题。
- 模块热重载后被误报为永久 `external_override` 的问题；同模块外部替换与真正模块代际变化分别处理。
- 测试隔离统一私有 XDG/TMP/日志目录并清理；修复 clangd 已知消息断言失效和并发快照未比较代次的问题。
- 首次多进程初始化数据目录时逐层创建并核对目录，修复中间父目录 EEXIST 导致单边同步失败的竞争。
