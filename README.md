# nvim-zh

面向 Neovim 的简体中文汉化插件。当前进度到**阶段 16：Help 全语料与核心消息目录完成后的全量复检与守卫补强**（未发布）。
核心消息继续使用 Neovim 自带 gettext，帮助使用 `.cnx`/`tags-cn`；独立的 Lua
引擎提供精确翻译、受控动态模板、用户数据 override 和本地缺失统计。UI 适配 notify、
UI prompt、可选 echo，以及 which-key/Telescope 公共显示接缝；
诊断与 clangd LSP 仅适配明确拥有的显示字段；不处理第三方插件私有 UI。

固定上游 0.12.6 的核心消息目录另有 130 条未译，本项目补完其中的 118 条并逐条
记录 12 条上游豁免；合并后的 MO 只在显式执行构建命令时产出，插件运行时不会自动
安装或替换系统 MO（见「核心消息汉化（native catalog）」）。

Help 译文当前 **133 份 `complete`**（逐篇状态以 `manifests/help_inventory.json` 为准），
manifest 里的正常用户文档已全部译完；`runtime/doc/*.txt` 中另外 2 篇按证据排除
（`credits.txt`、`uganda.txt`），仍回退英文，**不声称这 2 篇被翻译过**。

Help 译文固定上游 0.12.6；每份文档的 commit、源文件路径与 SHA-256 记录在
`manifests/upstreams.json`。当前覆盖范围和排除证据见下文及
`manifests/help_inventory.json`。

## 项目结构

| 路径 | 用途 | 编辑与检查 |
|---|---|---|
| `plugin/`、`lua/nvim-zh/` | Neovim 入口、翻译引擎及 UI/插件适配 | 行为契约在 `tests/phase1`–`phase7` |
| `translations/` | UI PO、native PO 与术语表的编辑源 | `make check-translations check-native` |
| `doc/*.cnx`、`doc/nvim-zh.txt` | 中文 Help 译文与插件帮助 | `make test-phase8` |
| `manifests/` | 固定上游、Help 覆盖状态及 native 豁免/修复证据 | `make test-phase8 test-phase9` |
| `tools/` | PO 构建、同步、Help 清单及翻译辅助工具 | `make test-phase6`–`test-phase9` |
| `tests/phase0`–`phase9` | 实验、单元测试、差分契约和发布检查 | `make test` |
| `.github/workflows/` | 离线版本矩阵与可选真实上游 smoke | CI 对 v0.12.6/v0.11.5/nightly 跑 `make test`（阶段 0–9，nightly `experimental`），对 v0.10.4 跑 `make test-foundation`；非 0.12.6 的上游比对按 `COMPATIBILITY.md` 的「版本差异与跳过规则」跳过并留痕 |

`lua/nvim-zh/catalogs/generated/*.lua` 由 UI PO 构建；`doc/tags`、`doc/tags-cn`
由 `:helptags doc` 生成；`manifests/help_inventory.json` 由
`tools/help_inventory.py` 生成。`build/upstream/` 缓存固定上游 PO，
`build/native/` 保存合并 PO、MO 与审计报告。这些产物都由命令生成，不手工编辑。
维护步骤和每类文件的检查入口见 `CONTRIBUTING.md`。

## 安装与配置

使用 lazy.nvim 时：

```lua
{
  'your-name/nvim-zh',
  lazy = false,
  priority = 1000,
  config = function()
    require('nvim-zh').setup({
      modules = {
        core = { enabled = true, apply_language = false },
        help = { enabled = true, lang = { 'cn', 'en' }, vimcdoc = false },
        ui = { notify = true, prompts = true, select_items = false, echo = false },
        plugins = { auto = true, lazy_load = true, disabled = {} },
        diagnostics = { enabled = true, virtual_text = true, virtual_lines = true, float = true },
        lsp = { messages = true, progress = true },
      },
      terminology = 'preserve',
      overrides = {},
      missing = { enabled = true, max_entries = 2000 },
    })
  end,
}
```

插件不会自动更改系统 locale。执行 `:NvimZhCheck` 或
`:checkhealth nvim-zh` 查看核心中文消息是否可用；`:NvimZhInfo` 显示当前
配置与资源路径。Vimcdoc 是独立可选依赖，不随本项目内嵌分发。
启用 `help.vimcdoc` 时，健康检查会排除本项目自带文档及其符号链接别名，
只把带 `tags-cn` 索引的外部中文帮助报告为 Vimcdoc 兼容资源。

## 翻译引擎

统一入口返回 `text, status, entry_id`，`status` 为 `translated` 或
`fallback`。任何未命中、目录错误或规则异常都返回原始英文：

```lua
local zh = require('nvim-zh')

zh.translate({
  domain = 'my-plugin',
  context = 'menu', -- 可省略；不会跨 context 泄漏
  msgid = 'Save',
})

zh.translate({
  domain = 'my-plugin',
  msgid = 'File {name}',
  args = { name = 'demo.lua' },
})

-- 已格式化文本只匹配目录中锚定、转义后的受控模板。
zh.translate({
  domain = 'my-plugin',
  msgid = 'File demo.lua',
  formatted = true,
})
```

命名参数优先；printf 参数保持原顺序和类型。引擎不做运行时模糊匹配，也不对
最终文本执行全局术语替换。翻译结果再次进入同一 domain 时不会重复翻译；
包装层也可传入 `translated = true` 明确跳过。

内置目录按 domain 首次使用时加载。用户 override 是纯 Lua 数据，必须显式
指定 domain 和 context（空 context 用 `''`），合并于内置目录之后：

```lua
zh.setup({
  overrides = {
    ['my-plugin'] = {
      [''] = { Save = '保存' },
      menu = { Open = '展开' },
    },
  },
})
```

override 不接受函数、loader 或可执行规则。`:NvimZhReload` 先重载目录和
override，再按 wrapper/formatter 所有权安全重建已加载插件的适配器。
重载会清理内置生成目录的 Lua 模块缓存，因此重新执行 `make build` 后不必重启
Neovim；用户注册的 loader 仍负责自己的依赖缓存。目录加载出错时回退原文。

## Neovim UI 适配

默认翻译 `vim.notify`/`vim.notify_once` 的消息以及 `vim.ui.input`/`vim.ui.select`
的 `prompt`、`title`。`level`、其他 opts、返回值、回调时序、原始输入和原始
item/index 保持不变。`notify_once` 先按英文原文去重，再在 `vim.notify` 边界翻译。

`select_items=true` 时仅包装公开 `opts.format_item`，不替换 items；默认关闭。
`echo=true` 时逐 chunk 翻译独立 `nvim-ui` domain 中允许的文本，保留高亮、扩展
元数据、history、opts 和 message id；默认关闭。fast event 直接调用原实现，不加载
目录或执行普通 IO。不会包装 `nvim_out_write`、终端输出流或私有 Buffer。

重复 setup 不叠加 wrapper；teardown 只恢复仍由本插件持有的函数。外部插件后替换
函数时，reload 不抢回函数，Info/health 报告 `external_override`。翻译异常和未命中
始终回退原文，原实现异常继续向调用方传播。

## 第三方插件

默认自动适配**已经加载且 API 形状兼容**的插件，不强制 `require`。`plugins.lazy_load=true`
使用 lazy.nvim 公开的 `User LazyLoad` 自动处理晚加载；其他管理器请在目标插件 setup 后
再次调用 nvim-zh setup 或执行 `:NvimZhReload`。

- which-key：公开 `replace.desc`，并在正常公开 setup 后安全重挂；直接外部替换不抢回。
- Telescope：公开 `pickers.new` 与 `Previewer:title`，覆盖静态/动态标题；false/nil 和未知
  标题保持原值，entry/previewer 数据不变。
- lazy.nvim：通知复用公开 `vim.notify`；主面板私有 view/Buffer/renderer 不适配。
- nvim-tree：链式公开 setup/on_attach，只翻译 mapping `desc`；lhs/rhs/buffer/调用顺序不变。
- nvim-cmp：固定版本中未找到可证明由 cmp 自己拥有的固定标签，保持 `inventory_only`；
  不翻译 abbr、kind/menu、completion item、source 或文档数据。

`plugins.disabled` 可分别禁用 `which-key`、`telescope`、`nvim-tree`。真实上游 smoke 默认
跳过；设置 `NVIM_ZH_TEST_WHICH_KEY`、`NVIM_ZH_TEST_TELESCOPE`、`NVIM_ZH_TEST_PLENARY`，
以及 `NVIM_ZH_TEST_LAZY`、`NVIM_ZH_TEST_NVIM_TREE`、`NVIM_ZH_TEST_NVIM_CMP` 后运行
`make test-phase4`。阶段 7C 还复核固定 `entry.lua` 与默认 formatter 源码 hash；
没有安全目标就不新增适配器。固定完整 commit 与源码 hash 见 manifest 和 `COMPATIBILITY.md`。

## clangd 诊断与 LSP 显示

`diagnostics` 只注入公开 virtual_text/virtual_lines formatter 和 float 调用 formatter；
用户 formatter 先运行且异常继续传播。`vim.diagnostic.get()`、quickfix、push/pull 原始诊断、
位置和 `user_data.lsp` 保持英文原数据。默认只识别 clangd/clang source 的 4 条静态规则；
固定 smoke 用 23.1.4 工具链（本机 PATH 现有 clangd 23.1.5），两者在固定 corpus 上都覆盖
5/7 个唯一消息（含 relatedInformation），两个 Expected 消息回退原文。
运行时观察覆盖率见 `require('nvim-zh.diagnostics').info()` 的 runtime_observed/runtime_translated；全局观察另见 `:NvimZhMissing`，都不代表全部 clangd。

用户 formatter 返回 `nil` 时继续隐藏该诊断；没有自定义 formatter 的 virtual_lines
保留 Neovim 默认的诊断码前缀。禁用模块或通道后，已交给外部的诊断 formatter、
nvim-tree on_attach 和 select format_item 回调也停止翻译，并继续调用原始回调。

`lsp.messages` 适配 clangd 的 showMessage/showMessageRequest 显示字段，返回原 action；
`lsp.progress` 只翻译 title/message，token、percentage、cancellable 与取消逻辑不变。
window/logMessage 默认保留原文。未知服务器和文本始终回退。外部工具没有安全公共显示
接缝，原始 stdout/stderr、日志、errorformat 输入和返回码均不修改。

## 缺失与覆盖率

`:NvimZhMissing` 显示当前进程内的去重缺失、出现次数和运行时观察统计。
容量由 `missing.max_entries` 限制；默认不上传、不写持久日志。动态文本、
路径和超长原文以 SHA-256 摘要标签代替原值。

`require('nvim-zh').stats()` 分别返回 `static.domains`（已加载静态目录）和
`runtime`（本进程实际观察）数据。它们都不是“全 Neovim 覆盖率”。

## 翻译资源维护

静态文本的编辑源为 `translations/po/zh_CN/*.po`，核心消息的补充译文在
`translations/native/*.po`（`zh_CN.po` 为上游形式补充，`runtime_repairs.po` 为按
固定源码重建的运行时键），术语约束位于
`translations/glossary/zh_CN.toml`。构建产物为按 domain 拆分的纯 Lua Table，
运行时不需要 `msgfmt`：

```bash
make check-translations  # PO、占位符、重复键、UTF-8、术语与代码保护检查
make build               # 可重复构建，稳定排序，不写入时间戳
```

Buffer、Window、Register 默认保留英文。该 glossary 是项目唯一的术语来源，**同时约束
UI 目录与 Help 正文（`doc/*.cnx`）**：`窗口`/`缓冲区`/`寄存器` 在任何交付的中文帮助里
都不得出现，由 `tests/phase8/test_help_terminology.py` 按 glossary 文件强制，新增
preserve 词条会自动扩展该检查。命令、快捷键、Lua API、选项、路径、
代码标识符和反引号内容必须原样保留；工具只检查，不自动改写。

### Help 文档译文

Help 译文位于 `doc/*.cnx`，通过 `doc/tags-cn` 与 `helplang=cn,en` 生效；缺失的
tag 自动回退英文。`manifests/upstreams.json` 为每份文档记录上游 repository、完整
commit、源文件路径、SHA-256、本地译文路径和 `complete`/`partial` 状态。

**逐篇状态以 `manifests/help_inventory.json` 为准**（由 `tools/help_inventory.py`
从固定 runtime 与 manifest 生成，`tests/phase8/test_help_inventory.py` 校验其可
逐字节重建）。当前 135 篇 `runtime/doc/*.txt` 的状态是：

| 状态 | 篇数 | 行数 | 含义 |
|---|---|---|---|
| `complete` | 133 | 130 515 | 整份译完并通过全部契约 |
| `partial` | 0 | 0 | 不允许计入完成 |
| `not_started` | 0 | 0 | 全部用户文档均已翻译 |
| `excluded` | 2 | 1 002 | 见下方证据 |

逐篇文档、类别、源文件 hash 与状态已列在 `manifests/help_inventory.json`，此处不再
维护另一份文件名列表。manifest 中没有 `not_started` 的用户文档；仅 2 篇
`excluded`（`credits`、`uganda`）。

**两篇 `excluded` 的证据**（`manifests/help_exemptions.json`，非用户文档）：

| 文档 | 排除理由 | 证据 |
|---|---|---|
| `credits.txt` | 署名与版权记录，不是用户文档 | `:1` 文件头、`:10` 作者、`:12` 起为贡献者姓名与致谢列表；许可证正文在 `uganda.txt`，此处不引用 `\|manual-copyright\|` |
| `uganda.txt` | Charityware 募捐与许可证正文 | 定义复制/许可条款，翻译会改变法律措辞 |

译文保留全部英文 help tag、`|链接|`、示例块和默认值说明；术语按 glossary 保留
Window/Buffer/Register 的英文写法；示例代码逐字节保留，可直接复制执行。新增文档时
同步更新 manifest、重新生成 `doc/tags-cn` 与 inventory：

```bash
nvim --headless -u NONE -c 'helptags doc' -c 'qa!'
python3 tools/help_inventory.py
```

## 核心消息汉化（native catalog）

Neovim 本体的 C/Vimscript 消息来自上游 gettext 目录。固定上游 0.12.6 的
`src/nvim/po/zh_CN.UTF-8.po` 共 1985 条消息：1855 条上游自带中文，130 条未译。
本项目把其中 118 条译完，msgid 逐字取自上游，可直接 `msgcat` 合并或提交上游；
其余 12 条是上游自己用 `# do not translate`（含“避免把中文写进文件”）标注的条目，
逐条证据记录在 `manifests/native.json` 的 `exemptions`，仍然回退英文，**不声称译过**。

| 状态 | 条数 | 位置 |
|---|---|---|
| 上游已译 | 1855 | 上游 `zh_CN.UTF-8.po` |
| 本项目补充 | 118 | `translations/native/zh_CN.po` |
| 上游标注不译（豁免） | 12 | `manifests/native.json` → `exemptions` |
| 合计 | 1985 | |

```bash
make check-native    # 离线：覆盖率、占位符序列、错误码、术语、UTF-8
make sync-native     # 仅在首次或换版本时显式联网，取回固定上游目录并校验 sha256
make build-native    # 合并上游 + 补充 + 修复，产出 build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo
make audit-native    # 可选：用本机 nvim 二进制核对补充条目的运行时字面量
```

上游目录里有两类“键对不上”的缺陷会让译文在运行时完全不生效，构建时一并修好：

| 缺陷 | 条数 | 处理 |
|---|---|---|
| 抽取 `PRIdVARNUMBER` 时未展开，msgid 被截断（如 `E5403: Chunk %i start %`） | 4 | `translations/native/runtime_repairs.po` 按固定上游 C 源码重建运行时 msgid |
| 同一消息在运行时还有一条带 `E###: ` 前缀的调用点，po 只记录了无前缀键 | 25 | manifest 的 `prefix_repairs`，构建时补同前缀条目 |

`make audit-native` 在本机固定二进制及其 runtime 树（sha256 记入 manifest 的
`runtime_audit`）上实测：118 条补充中 76 条直接对上二进制字面量、25 条另有带前缀
字面量（已补同前缀条目）、2 条来自 `runtime/scripts/optwin.lua` 这类运行时文件；
其余 15 条在二进制与 runtime 树中都找不到字面量，因此**不声称**它们已生效——其中
4 条已确认是上游 po 措辞过期（如 `E5100` 的 “lua table” vs 运行时的 “Lua table”），
证据逐条记在 manifest 的 `runtime_audit.stale_upstream_msgids`。真实生效证据
（临时 prefix + 临时 locale 下触发 E482、E576、E136、E5005 片段）见 `COMPATIBILITY.md`。

构建只写 `build/` 目录，**不安装、不替换**系统或 Neovim 自带的任何 MO；装卸与接线
属于后续显式集成步骤，插件 `core` 模块当前仍只读取发行版自带目录。

## 测试

```bash
make test          # 阶段 0–9（离线 Lua、差分契约、Python 工具与发布检查）
make test-phase0   # 原生机制实验
make test-phase1   # 原生 MVP 集成规格
make test-phase2   # 引擎、目录、缺失、命令、模糊输入与性能读数
make test-phase3   # UI 差分契约、wrapper 生命周期、echo、模糊输入与性能读数
make test-phase4   # 插件公共接缝、晚加载、动态标题与真实上游可选 smoke
make test-phase5   # clangd 诊断/LSP 差分契约、push/pull 与外部字节边界
make test-phase6   # 同步 fixture、版本清单、relay/catalog 安全回归、可重复构建与发布清洁检查
make test-phase7   # 真实观察诊断契约与 smoke 仪器负向回归；clangd/cmp smoke 默认 SKIP
make test-phase8   # Help 跨版本 tag/示例块/链接契约、基线 hash、tags 与 :helptags 一致性、LSP 显示文本
make test-phase9   # 核心消息补充目录、豁免/修复清单、合并与 MO 可重复构建
make check-native  # 核心消息译文离线校验（phase9 的子集，可单独跑）
make build-native  # 合并固定上游目录并产出 MO（离线；首次先 make sync-native）
make test-foundation # 0.10 基础引擎、native health 与原生帮助能力
make sync          # 默认离线只读（不联网）
make sync-fetch    # 显式只读联网同步 UI 目录（--fetch 是工具参数，不是 make 参数）
```

阶段 9 的真实运行时探针默认跳过（`skipped=2`）；设置
`NVIM_ZH_TEST_NATIVE_RUNTIME=1` 后会在临时 prefix + 临时 locale 下用副本 nvim
验证 `E482`、`E576`、`E136`、`E5005` 的译文与「豁免条目保持英文」，并断言随包
`build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo` 等于按缓存固定上游 PO 重建的结果。

可用 `NVIM_BIN=/path/to/nvim` 指定 Neovim，用 `PYTHON=/path/to/python3`
指定 Python（phase7–9 的 shell 入口会把它传给 Python 检查器）。`make test`
的阶段 0–9 在所有支持版本上执行，并用 `.NOTPARALLEL` 串行化聚合目标：
阶段 6 的 relay/catalog 安全回归会临时重定向工具根目录并注入写失败，
因此不能与其他阶段的重建并发。阶段 8 分两层：

- **译文与固定上游之间的 tag / 示例块 / `|链接|` / 文件尾部契约**记录在
  `manifests/help_inventory.json` 的 `contract` 摘要里（`tail_digest` 覆盖末行 modeline
  及其后的全部字节），由 `01_help_catalog_spec.lua` 在 pinned 守卫**之前**断言，
  **在所有版本执行**——在 0.11.5/nightly 上删一个 tag、改一个示例块、动一个链接或改坏
  末行 modeline 都会失败；`tests/phase8/test_help_inventory.py` 另用同一套引擎重算这些
  摘要并与清单逐字段比对（不读 `$VIMRUNTIME`，同样在所有版本执行）；
- 需要读运行中 `$VIMRUNTIME` 的比对（逐篇源文件 hash、全文 parity、上游字面量、
  `:helptags` 再生成相等）只对 manifest 固定的 0.12.6（`pinned=true`）成立，其他
  版本按 `upstream_absent` / `HELP_PARITY=SKIP` 跳过，`SKIP` 行会打印被跳过的
  **篇数与 tag 数**（见 `COMPATIBILITY.md` 的「版本差异与跳过规则」）。自报固定版本
  但为 prerelease 的构建（如 `0.12.6-dev`）会直接报错，不会静默降级为 unpinned；
  `pinned` 判定前会用 manifest 的 sha256 抽查首/中/尾三篇实际 runtime 文档。

阶段 0 研究测试需要 gettext 的 `msgunfmt`；
可选 E1 正向控制
还需要 `localedef` 和系统 locale source。阶段 2/3/4/5 性能输出只表示当前机器，
不设跨机器阈值。真实 clangd smoke 使用
`NVIM_ZH_TEST_CLANGD=/absolute/path/to/clangd make test-phase7`；本机实测版本、pull
限制和分母见 `COMPATIBILITY.md`。

## 架构边界

`generated catalogs → catalog → engine → ui/plugins/diagnostics/lsp`，适配器只调用统一引擎；`missing`
只记录本地观察，help/native 保持独立。`manifests/upstreams.json` 固定 Neovim 版本、commit 和文档 SHA-256，
`manifests/native.json` 固定核心消息目录的 commit、SHA-256、缺口、豁免与修复清单。核心消息在运行时仍由
上游 MO 提供；本项目只额外维护译文资源与可复现的合并产物，不自动安装、不实现第二套运行时目录接管。

## 维护与发布

翻译贡献见 `CONTRIBUTING.md`，实测兼容矩阵见 `COMPATIBILITY.md`，变更与人工发布流程见
`CHANGELOG.md`、`RELEASE_CHECKLIST.md`。项目当前不是 Git worktree；未初始化、提交、打 tag 或发布。
