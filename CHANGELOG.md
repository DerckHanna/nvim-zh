# Changelog

本项目遵循语义化版本。未打 tag、未发布。

## [0.1.0] - Unreleased

### Added

- 原生中文资源检查、中文帮助、纯 Lua PO 目录和统一精确翻译引擎。
- notify/UI、which-key、Telescope（含公开动态 previewer 标题）适配。
- lazy.nvim 晚加载事件与 nvim-tree 公开 on_attach mapping 描述适配。
- clangd 固定 corpus 的诊断显示、showMessage/showMessageRequest 与 progress 显示适配。
- 离线同步报告、显式只读联网同步、CI 版本矩阵、可重复构建与发布清洁检查。
- 阶段 7 真实 clangd 23.1.4 push smoke 与原始观察 fixture；新增 2 条安全诊断模板。
- 诊断静态目录 4 条、固定 corpus 5/7；真实 pull 明确记录为服务器不支持。
- Neovim 0.11.5 与固定 nightly 完整离线矩阵、0.10.4 基础能力实测；nightly 仍仅作预警。
- 0.11/0.12/nightly 的 pull 契约统一使用公开 in-process client attach/request 生命周期，不访问私有 enable/active state。
- nvim-cmp 固定 formatter/entry 源码复审，继续 inventory_only；外部工具字节不变。
- formatted 输入中似占位符文本通过同一锚定模板引擎原样捕获并翻译。
- 阶段 8：新增 5 份完整翻译的 Neovim 0.12.6 Help 文档（`help.cnx` 默认 `:help`
  落地页、`nvim.cnx`、`lua-guide.cnx`、`diagnostic.cnx`、`terminal.cnx`），manifest 改为多文档
  结构并逐份记录上游 commit、源路径、SHA-256 与 complete/partial 状态。
- 阶段 8：新增 Neovim 自身通过 `vim.notify` 显示的 LSP 提示 7 条与
  `vim.ui.input`/`vim.ui.select` 提示 3 条（`nvim-ui` domain），只覆盖固定 0.12.6
  源码中存在的原文字面量。
- 阶段 8：新增 `tests/phase8`，验证多文档 tag 双向一致、示例块与 `|链接|` 不变、
  `doc/tags`/`doc/tags-cn` 与 `:helptags` 输出一致、`make test` 不产生 `nvim.log`。
- 修复：Neovim 在只读 state 目录时会向当前目录写 `nvim.log`，导致 `make release-check`
  误报；全部阶段运行器改用私有 `XDG_STATE_HOME` 并在退出时清理。
- 阶段 9：新增 2 份完整翻译的 Neovim 0.12.6 Help 文档——`quickfix.cnx`（2 443 行源文，
  273 个 tag，98 个示例块）与 `lsp.cnx`（3 215 行源文，204 个 tag，79 个示例块），
  累计 7 份 complete 文档、693 条 `doc/tags-cn`。
- 阶段 9：`nvim-ui` domain 增加 8 条 LSP 通知（格式化、重命名、层级、文档颜色、关联
  编辑、textDocumentSync），domain 总数 34 → 42；每条都能指到固定源码行。
- 阶段 9：新增 `tests/phase8/check_help_parity.py`，逐条报告全部 tag/示例块/链接偏差，
  解决 Lua 契约遇首个失败即中止、难以整篇校对的问题；已接入 `make test-phase8`。
- 阶段 9 续：再新增 2 份完整翻译的 Help 文档——`windows.cnx`（1 452 行源文，267 tag，
  26 示例块）与 `cmdline.cnx`（1 410 行源文，239 tag，50 示例块），累计 9 份 complete、
  1 199 条 `doc/tags-cn`。
- 修复：`01_help_catalog_spec.lua` 的示例块开口判定漏掉了 help.vim 规则中的
  `\%(^\| \)` 前缀，会把 `type <Enter>` 之类以 `>` 结尾的散文误判为示例块开头，
  导致块边界漂移；现按上下文自由文法重写（Lua 模式无 `|` 交替）。
- 修复：`test_help_catalog.py` 重建 `:helptags` 模式时只转义反斜杠，未转义 `/`，
  遇到 `cmdline.txt` 的 `/_<Tab>` tag 会误报；现同时转义两者。
- 新增 `tests/phase8/03_help_parity_rules_spec.lua`，把上述两条规则（示例块开口谓词、
  `:helptags` 模式重建）连同 `doc/tags-cn` 全量模式一致性钉死，防止校验被静默削弱。
- 阶段 9 续：新增 `motion.cnx`（1 411 行源文，305 tag，19 示例块，189 链接），
  覆盖操作符与移动、`f`/`t`/`w`/`e` 系列、文本对象与标签块、标记、跳转列表和改动
  列表；累计 10 份 complete、1 504 条 `doc/tags-cn`。
- 阶段 9 续：新增 `editing.cnx`（1 742 行源文，248 tag，62 示例块，238 链接），
  覆盖编辑/写出/退出、参数列表全表、`[++opt]`/`[+cmd]`、文件格式与 EOL/EOF、
  备份与 ACL/xattr、目录作用域、二进制编辑、时间戳、文件搜索与受信任文件；累计
  11 份 complete、1 752 条 `doc/tags-cn`。
- 阶段 10：Help 文档从 11 份扩展到 **45 份 `complete`**（30 783 行源文、3 952 条
  `doc/tags-cn`），新增 34 份：编辑与操作核心（`change`、`visual`、`undo`、`scroll`、
  `fold`、`diff`、`userfunc`、`vvars`）、搜索与命令行（`pattern`、`tagsrch`、
  `starting`、`repeat`、`message`、`gui`、`tui`、`tabpage`、`sign`、`health`）、
  打包、远端与随包插件（`plugins`、`provider`、`remote`、`remote_plugin`、
  `pi_gzip`、`pi_paren`、`pi_tutor`、`pi_msgpack`）、
  文件类型与本地化（`ft_ps1`、`ft_hare`、`rileft`、`l10n-russian`、
  `l10n-vietnamese`），以及 `support`、`helphelp`、`job_control`。每份译文都保留全部
  英文 help tag、`|链接|` 与逐字节一致的示例块。
- 阶段 10：新增 `tools/help_inventory.py` 与 `manifests/help_inventory.json`，为全部
  135 篇 `runtime/doc/*.txt` 记录逐篇状态（`complete`/`partial`/`not_started`/
  `excluded`）、行数、tag/示例块/链接数与源文件 SHA-256；`manifests/help_exemptions.json`
  记录唯一 2 篇排除对象（`credits.txt`、`uganda.txt`）的具体证据。新增
  `tests/phase8/test_help_inventory.py`，钉死清单覆盖每一篇 runtime 文档、与 manifest
  一致、且可逐字节重建。
- 阶段 10：glossary 的 `preserve` 规则扩展到 Help 正文。全库 879 处「窗口/缓冲区/
  寄存器」按 `translations/glossary/zh_CN.toml` 改为 `window`/`buffer`/`register`
  （19 个文件）；新增 `tests/phase8/test_help_terminology.py`，规则直接读 glossary
  文件，新增 preserve 词条会自动扩展检查。
- 修复：`:helptags` **不会**索引示例块内部的 `*tag*`。`helphelp.txt` 在示例里演示帮助
  文件头部格式（含 `*plugin_name.txt*`），而 phase8 的 tag 扫描器原来把块内文本也算作
  tag，于是要求一个 `:helptags` 永远不会写出的 `tags-cn` 条目——两项契约互相矛盾。
  现在 Lua 与 Python 扫描器都像 `:helptags` 一样跳过示例块内部，同类文档还有
  `autocmd.txt` 与 `usr_41.txt`；`test_help_catalog.py` 新增用例直接钉死 `:helptags`
  的这条规则，避免将来再次退化成“必须为空”的假 PASS。
- 阶段 10：`doc/*.cnx`、`doc/tags`、`doc/tags-cn` 权限统一为 644（此前部分为 600，
  会妨碍按包分发后其他用户读取）。
- 阶段 10 续：Help `complete` 从 45 份扩展到 **58 份**（48 644 行源文、5 418 条
  `doc/tags-cn`），新增 13 份：`insert`、`autocmd`、`map`、`indent`、`filetype`、
  `spell`、`treesitter`、`vim_diff`、`usr_01`、`usr_02`、`usr_04`、`usr_10`、
  `usr_41`。剩余 75 篇仍为 `not_started`。
- 文档补记：`:helptags` 跳过示例块内部 tag 的规则、以及「闭合 `*` 后必须紧跟 ASCII
  空白否则 tag 被静默丢弃」这两条陷阱写入 `CONTRIBUTING.md`。
- 修复：`tools/help_relay.py` 的 `assemble()` 把 `inject_text()` 的两个参数传反
  （拿整篇译文当上游文件名），任何一次 `assemble` 都会以 `File name too long` 崩溃——
  也就是说「注入示例块体」这一步此前从未真正跑通过。修正后对 `luvref.cnx` 完整走通
  「骨架 → 注入 → 整篇 tag/示例块/链接逐字节契约」。
- 阶段 11：`tools/help_relay.py` 新增 `check-segment` 子命令，并在
  `tools/HELP_RELAY_PROTOCOL.md` 补「分段模式（segment mode）」：把一篇文档的剩余
  区间切成互不重叠、不切开示例块的若干段，每段一个代理并行产出独立段文件；每段用
  `skeleton(upstream[FROM-1:TO])` 精确自检（tag 双向一致、`|链接|` 计数、示例块数、
  `@@BLOCK@@` 后继必须顶格、术语与编码），全部 PASS 后再按序拼接并注入。`target()`
  现在优先识别 `doc/<name>.cnx.partial`，`verify`/`assemble` 可直接作用于进行中的
  接力文件。
- 阶段 11：新增 `luvref.cnx`（4 642 行源文，295 tag，23 示例块，190 链接），覆盖
  luv/libuv API 参考全文（handle / stream / process / thread / filesystem / DNS /
  metrics 各章与 CREDITS）；同时补齐旧稿整段漏译的 `*uv.spawn-options*`。累计
  **129 份 `complete`**（100 652 行源文）。
- 修复：5 份 `.cnx.partial` 旧稿共有 29 处块边界缺陷——`@@BLOCK@@` 后面跟着空行或
  缩进正文，注入后块体会把后续散文一起吞掉，导致示例块体漂移。逐处对齐上游
  terminator（删掉多余空行；上游是顶格 `<` 的地方补回 `<`）后，四份仍未完成的旧稿
  在「骨架 → 注入 → 比对块体」下零偏差。另修掉 `syntax` 旧稿里重复写入的一对
  fence + 占位符，以及 `vimfn` 旧稿里因闭合 `*` 前缺 ASCII 空格而丢失的 `*E1132*`。
- 阶段 11 续：最后 4 篇大型 Help 文档用「分段模式」并行接力译完，`complete` 从 129 份
  扩展到 **133 份（130 515 行源文）**：`syntax.cnx`（5 703 行源文，552 tag，437 示例
  块）、`vimeval.cnx`（3 943 行源文，519 tag，293 示例块）、`options.cnx`（7 726 行
  源文，1 115 tag，183 示例块）、`vimfn.cnx`（12 491 行源文，581 tag，522 示例块）。
  18 个段各自独立产出骨架段，每段都用 `check-segment` 对照
  `skeleton(upstream[FROM-1:TO])` 精确自检（tag 双向、`|链接|` 计数、示例块数、
  顶格 terminator、术语、编码），全部 PASS 后才按序拼接并 `assemble` 注入块体；
  四篇都通过整篇 tag / 示例块 / 链接逐字节契约，且 `:help <name>.txt` 实测打开中文
  `.cnx`。
- 清理：删除仓库根目录的 `b5.py`、`vis.py`、`vis2.py`——上一轮修补 `doc/index.cnx`
  时留下的一次性探针脚本，全仓库无任何引用。`HELP_TRANSLATION_CONTRACT.md` 要求仓库内
  不得留探针脚本，现已符合；`doc/index.cnx` 本身未改动且仍通过 parity 契约。

- 阶段 12：补齐 Neovim 本体核心消息。固定上游 0.12.6 `src/nvim/po/zh_CN.UTF-8.po`
  的 1985 条消息中有 130 条未译，本项目译完 **118 条**（`translations/native/zh_CN.po`，
  msgid 逐字取自上游，可直接合并/提交上游），其余 12 条按上游自己的
  `# do not translate` 标注豁免并逐条记录 marker、refs 与理由（`manifests/native.json`）。
- 阶段 12：新增 `tools/native_catalog.py`（`check`/`build`/`sync`/`stats`/`audit`）与
  `manifests/native.json`：固定上游 commit、SHA-256、130 条缺口、12 条豁免、修复清单；
  `make check-native`、`make sync-native`、`make build-native`、`make audit-native`
  接入 Makefile。构建产出 `build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo`，可重复。
- 阶段 12：修掉两类让译文在运行时失效的上游目录缺陷——4 条 msgid 因
  `PRIdVARNUMBER` 未展开而被截断（`E5403`–`E5406`，在
  `translations/native/runtime_repairs.po` 按固定 C 源码重建运行时键），25 条消息在
  运行时另有一条带 `E574/E575/E576/E886/E136` 前缀的调用点（manifest 的
  `prefix_repairs`，构建时补同前缀条目）。
- 阶段 12：新增 `tests/phase9`（离线为主体），校验覆盖率、占位符序列、错误码、
  术语、豁免/修复清单、合并结果与 MO 可重复构建；可选运行时探针
  （`NVIM_ZH_TEST_NATIVE_RUNTIME=1`）在临时 prefix + 临时 locale 下用副本 nvim
  实测 `E482`、`E576`、`E136`、`E5005` 片段中文生效，豁免条目仍英文。
- 阶段 12：`COMPATIBILITY.md` 记录固定上游 po、二进制与审计读数：118 条补充中 76 条
  对上二进制字面量、25 条另有带前缀字面量（已补）、2 条来自 `runtime/scripts/optwin.lua`
  等运行时文件、15 条在两个范围内都找不到字面量（不声称生效）。其中 4 条已确认是上游
  po 措辞过期（`E5100`/`E5101`/`E5114`/`--server` 帮助行），证据记入 manifest 的
  `runtime_audit.stale_upstream_msgids`，需上游更新 po。
- 修复：`tests/phase8` 的运行时比对原来对非 0.12.6 版本也按固定 0.12.6 断言，于是
  0.11.5（runtime 缺 10 篇固定文档）与 nightly（缺 `pi_zip.txt`）会在
  `01_help_catalog_spec.lua`、`02_lsp_ui_text_spec.lua` 或 `check_help_parity.py`
  整段中止（`make test` 因此在 `test-phase8` 失败，phase9 根本不执行）。现按 manifest
  固定的 0.12.6 判定 pinned：非 pinned 只跳过**上游**比对并把该篇标为 `upstream_absent`
  或打印 `HELP_PARITY=SKIP`，译文自身的 tag/示例块/链接契约仍在所有版本执行，0.12.6
  的严格性不变。
- 修复：`doc/tags`、`doc/tags-cn` 与 `:helptags` 再生成的逐条相等原来在任意版本断言；
  0.11.5 的 `:helptags` 索引更窄（`E767`、`[q`、`quote:`、`uv.pipe_chmod()` 等 tag 名
  不会生成）会误报。该相等现只在 pinned 断言，并新增"随包 tags 在运行版本可解析"的
  用例（13 个抽样 tag，含上述特殊字符 tag 与英文回退），把跨版本可用性变成受检契约。
- 新增 `tests/phase8/test_help_parity_skip.py`：用报告 0.11.5 的假 nvim 驱动真实
  `check_help_parity.py`，断言非 pinned 走 `HELP_PARITY=SKIP` 且 pinned 反例仍真比对；
  另在 `tests/phase6` 增加结构断言，防止三处版本守卫被静默移除。
- 修复：`tools/help_relay.py` 把上游路径写死为 `/usr/share/nvim/runtime/doc`，在非 Arch
  或非 0.12.6 环境会失败，更糟的是**静默**用错版本的上游文本生成翻译计划；现按
  `--runtime`/`$NVIM_ZH_RUNTIME`/`$VIMRUNTIME`/`$NVIM_BIN` 解析，并在使用前按 manifest
  sha256 校验，不匹配直接拒绝。`tools/native_catalog.py audit`、`tests/phase9` 的真实
  运行时探针改为使用 `--binary`/`NVIM_BIN` 自身的 `$VIMRUNTIME`，
  `tools/help_inventory.py` 的探测也改用 `NVIM_BIN`；两份 relay/contract 文档不再写死
  系统路径。
- 阶段 13：四版本矩阵复验（2026-11-14）——0.12.6、0.11.5、nightly
  `0.13.0-dev-2081+g5a53f3bb9e` 的 `make test`（阶段 0–9）与 0.10.4 的
  `make test-foundation` 全通过；0.12.6 的 `HELP_PARITY` 仍为 133 篇 0 问题，0.11.5
  与 nightly 打印 `upstream_absent`（10 篇 / 1 篇）与 `HELP_PARITY=SKIP`。矩阵 scope 与
  status 同步到 `manifests/upstreams.json` 与 `COMPATIBILITY.md`（新增「版本差异与跳过
  规则」小节，含 0.11.5 `:helptags` 的 `E670` 与 tag 名差异证据）。

- 阶段 14：独立复检后的修复（2026-11-14）。
  - **修复（严重）**：`:helptags` 在 Neovim 0.10/0.11 上会把 `doc/tags-cn` 覆盖成
    空文件。这两版的 `src/nvim/help.c`（`helptags_one()`）只按**首行**判定编码
    （首行含非 ASCII 字节 = utf-8，纯 ASCII = latin1），同一目录里两种混用时抛
    `E670` 并中止整个语言、不写任何条目，而进程仍以 0 退出。`ft_hare`、`ft_ps1`、
    `ft_raku`、`pi_msgpack`、`pi_tutor` 这 5 篇译文把中文标题直接写在首行，违反了
    契约第 10 条「首行逐字节照抄上游」；现改回上游 ASCII 首行、中文标题另起一行，
    134 篇首行统一为 ASCII。0.11.5 上的 `:helptags` 重新生成现与随包 `doc/tags-cn`、
    `doc/tags` 逐字节一致。
  - 新增三条跨版本守卫：`test_first_lines_share_one_encoding_class`（首行必须 ASCII）、
    `test_helptags_regeneration_is_not_destructive`（再生成不得报 `E670`/`E15x`，且
    `tags-cn` 不得被截断）、`test_shipped_tags_are_internally_consistent`
    （`tags-cn`/`tags` 与 `doc/*.cnx`/`doc/*.txt` 双向一致）。
  - **修复（严重）**：`tests/phase7/foundation.sh` 缺少 `XDG_STATE_HOME` 隔离，只读
    HOME 下 `make test-foundation` 会往仓库根写 `nvim.log`（0.12.6）或 `.nvimlog`
    （0.11.5/0.10.4）；`tools/catalog_tool.py` 的发布清洁检查识别不到 `.nvimlog`
    （前导点使 `Path.suffix` 为空），`tests/phase6` 的守卫也只 glob `phase*/run.sh`
    因而漏掉该入口。三处同时修复：入口加隔离与 `trap`、清洁检查增加名称黑名单、
    结构断言扩展到 `phase*/foundation.sh` 并新增 `.nvimlog` 反例。
  - **修复（契约）**：「译文自身的 tag/示例块/链接契约在所有版本执行」此前并不成立
    ——这些比对都在 `if pinned` 内，0.11.5 上删除 tag 或改写示例块仍然 PASS。现在
    `tools/help_inventory.py` 为每篇译文记录由**固定上游**算出的
    `contract.tags_digest`/`blocks_digest`/`links_digest`（外加三个计数），
    `01_help_catalog_spec.lua` 在 pinned 守卫**之前**用 `vim.fn.sha256` 断言它们；
    实测 0.11.5 上删 tag 报 `tag count changed: expected 22, got 21`、改示例块报
    `example blocks changed`（修复前两者都静默通过）。
  - `check_help_parity.py` 的 `HELP_PARITY=SKIP` 行补上被跳过的篇数与 tag 数，并在
    宣布 pinned 前先用 manifest 的 sha256 抽查实际 runtime，避免仅凭 `--version`
    自报版本就当成基线。
  - `tests/phase8/test_help_inventory.py` 原本用类级 `skipUnless` 在非 pinned 版本跳过
    全部 7 项（其中 5 项只比较仓库内 JSON）；现只对两项依赖 `$VIMRUNTIME` 的用例跳过。
  - `tests/phase1/04_docs_spec.lua` 不再无条件读 `$VIMRUNTIME/doc/nvim.txt`（缺失时
    报明确错误而不是 io.assert），并与 `01_help_catalog_spec.lua` 一起改为从 manifest
    推导 pinned 版本/commit，不再各存一份硬编码。
  - 文档更正：`COMPATIBILITY.md` 的 0.12.6 矩阵行 LuaJIT 版本改为实测
    `2.1.1794386141`；删去「0.11.5 的 `:helptags` 索引更窄（`E767`/`[q`/`quote:`/
    `uv.pipe_chmod()` 不会生成）」这一不可复现的说法——同一输入下 0.11.5 与 0.12.6
    生成的 tags 逐字节相同，真实症状是 `E670` 使该语言产出 0 行；新增「首行编码规则」
    与「require 两层契约」说明，`README.md` 的对应措辞同步改写。

- 阶段 15：独立复检发现的问题修复（2026-11-14）。
  - 跨版本守卫补全：`tests/phase8/03_help_parity_rules_spec.lua` 原先只逐行校验
    `doc/tags-cn` 的第三列搜索模式，`doc/tags`（21 条，插件自有命令 tag）的模式只在
    pinned 的再生成相等里被间接覆盖。实测在 0.11.5 上把 `:NvimZhInfo` 的模式改坏，
    修复前 `make test-phase8` 仍通过；现在两个索引文件用同一规则逐行校验
    （`HELP_PARITY_RULES_SPEC=PASS tags=10798 tags_txt=21`），同样的改动会报
    `tags pattern for :NvimZhInfo: expected "/*:NvimZhInfo*"`。
  - pinned 分类不再静默降级：自报固定版本但 `vim.version().prerelease` 非空的构建
    （如 `0.12.6-dev`）原先被判为 unpinned，从而跳过**全部** `$VIMRUNTIME` 比对；
    现 `01_help_catalog_spec.lua`、`02_lsp_ui_text_spec.lua`、`04_docs_spec.lua`
    一律硬报错 `pinned/unpinned cannot be decided`。同时 `02_lsp_ui_text_spec.lua`
    改为从 manifest 读取固定版本（此前它是第三处硬编码 0.12.6 的地方）。
    `tests/phase8/test_help_parity_skip.py` 用注入 `vim.version` 的 shim 做正反对照：
    `0.12.6+dev` 在三个 spec 上都报错，`0.13.0-dev` 仍走 unpinned 并打印
    `DOCS_SPEC=PASS`（证明该门不是恒失败）。
  - `check_help_parity.py` 在宣布 pinned 前的 sha256 抽查由「第一篇存在的文档」改为
    首/中/尾三篇（`probe_documents()`），并补上「自报 pinned 但内容不符」的端到端
    反例（`HELP_PARITY=FAIL reason=pinned_runtime_content_mismatch`）——该分支此前
    没有测试覆盖。
  - `tests/phase6/test_maintenance.py` 增补结构断言：两个索引文件的模式校验、三个
    spec 的 prerelease 门、`probe_documents()` 与两个新反例用例都不得被静默移除
    （phase6 `Ran 12`）。
  - 注释与文档更正：`tests/phase8/test_help_catalog.py` 的模块 docstring 不再声称
    「0.11.5 索引更窄」（0.11.5 再生成两个索引文件与随包逐字节相同，`E767`/`[q`/
    `quote:`/`uv.pipe_chmod()` 都在），改为说明 pinned-only 的真实理由；
    `01_help_catalog_spec.lua` 的注释改指向真正做跨版本模式校验的 03；
    `COMPATIBILITY.md` 的「134 篇首行」改为「133 篇译文 + 1 篇插件自有帮助」。
  - 复验（2026-11-14）：0.12.6 的 `make check-translations check-native build
    build-native sync check-reproducible test release-check` 全 EXIT=0
    （`RELEASE_CHECK=PASS files=265`）；0.11.5 与 nightly 的 `make test`、0.10.4 的
    `make test-foundation` 全通过，0.11.5/nightly 的 phase8 当时为
    `Ran 7 OK (skipped=2)`、`Ran 8 OK (skipped=2)`、`Ran 6`（阶段 16 为 inventory 增加
    一项运行时无关的契约交叉核对后为 `Ran 9`），`HELP_PARITY=SKIP` 行仍带
    `documents=133 tags=10798` 分母；在 0.11.5 上改坏 `doc/tags` 的第三列现在会失败
    （修复前通过）。本轮窗口内未改动 `manifests/upstreams.json`、`doc/tags`、
    `doc/tags-cn`、`lua/`、`plugin/`、PO/glossary，合并 MO sha256 仍为 `6c4622ef…`。

- 阶段 16：全量复检（A–F 全矩阵）后的修复（2026-11-14）。
  - **修复（严重）**：`make check-reproducible` 是**恒真门**。该 recipe 是单条 shell
    命令列表且没有 `set -e`，退出码取自末尾的 `echo REPRODUCIBLE_BUILD=PASS`，因此
    `diff -ru` 明确报出差异也照样打印 PASS 并以 0 退出；`release-check` 依赖它，于是
    「PO → Lua 目录」漂移没有任何发布门禁能发现。实测：篡改
    `lua/nvim-zh/catalogs/generated/nvim-zh.lua` 的一个 `msgstr` 后，
    `make check-reproducible`、`make release-check`、`make test-phase6` 三者全部
    EXIT=0 且都打印 `REPRODUCIBLE_BUILD=PASS`。现在该 recipe 以 `set -e` 开头，同样的
    篡改会让它失败（干净树仍然 PASS）。
  - **修复（严重）**：`doc/lua-guide.cnx` 末行 modeline 多一个前导空格、
    `doc/starting.cnx` 在 modeline 之后多一个空行，违反
    `tools/HELP_TRANSLATION_CONTRACT.md` 第 10 条「末行逐字节照抄上游」，而原有的
    tag/示例块/链接摘要都看不到文件尾部（实测 131/133 篇尾部一致，只有这两篇不同）。
    两篇按上游字节改正后 133/133 篇的「最后一个非空行到 EOF」与上游逐字节一致；并在
    `contract` 里新增由固定上游算出的 `tail_digest`，`01_help_catalog_spec.lua` 在
    **所有**版本断言它。
  - `tests/phase8/test_help_inventory.py` 新增与 `$VIMRUNTIME` 无关的
    `test_translation_contracts_match_the_shipped_translations`：用生成 `contract` 的
    同一套引擎（`tools/help_inventory.py`）重算每篇译文摘要并与
    `manifests/help_inventory.json` 比对。此前非 pinned 版本只校验 `contract` 的
    **形状**，把某个字段改成 `0…0` 或两篇互换都不会失败（实测 `OK (skipped=2)`）。
  - `tests/phase9` 的运行时探针原先只断言 `E482` 与 `E576`；现补齐 `E136`、`E5005`
    与「上游 `# do not translate` 豁免仍为英文」，并新增
    `test_shipped_mo_is_the_pinned_rebuild_and_translates_every_documented_row`：用缓存
    的固定上游 PO 重建 MO、断言它与随包 `build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo`
    逐字节相同（原生目录此前没有这一层守卫，`check-reproducible` 只覆盖 UI 目录），再在
    临时 prefix + 临时 locale 下探针。阶段 9 从 14 项增至 15 项（默认 `skipped=2`）。
  - `tests/phase6/test_maintenance.py` 的结构守卫由文本子串改为整词/整字面量断言。
    实测这些「保留子串」的改名原先都能骗过断言：`XDG_STATE_HOME` →
    `XDG_STATE_HOME_UNUSED`、`tags_digest` → `tags_digest_RENAMED`、
    `check_tags_file('doc/tags-cn'` → `…-DISABLED`、以及只替换首处 `upstream_absent`
    （`replace(..., 1)`）。现在它们都会 FAIL。
  - `make sync --fetch` 按字面不可执行（`--fetch` 是工具参数而非 make 参数，实测
    `make: unrecognized option '--fetch'`，EXIT=2）。新增 `make sync-fetch` 作为 UI 目录
    的显式只读联网入口，`README.md`、`RELEASE_CHECKLIST.md` 的措辞同步。
  - 文档更正（均为本轮实测）：`COMPATIBILITY.md` 的「本机 PATH 无 clangd」已过期
    ——系统现有 `/usr/sbin/clangd`（`clangd version 23.1.5`，clang `23.1.5-1`），固定
    smoke 仍在 `/tmp` 解包 `llvmorg-23.1.4` 并实测通过，两套读数并列记录；
    `credits.txt` 的排除证据引用错文件（`|manual-copyright|` 在 `uganda.txt:34`，
    `credits.txt` 命中 0 处），改引 `credits.txt:1/:10/:113` 与
    `uganda.txt:7/:33-:34`；`build/native/audit.json` 的分类键是 `bare` 而不是表里的
    `bare_only`，并补上此前漏列的 `prefixed_only`；clangd 的 `4/6` 补上分母说明；
    `CHANGELOG.md` 的「17 条」与自身另四处及 manifest 的 15 条矛盾，改为 15；
    `tools/HELP_TRANSLATION_CONTRACT.md` 的「与其余 129 篇一致」改为 133；
    `README.md` 的进度指针从阶段 12 更新到阶段 16。
  - `tools/HELP_RELAY_PROTOCOL.md` 记下 `target()` 的取值优先级：`doc/<name>.cnx`
    存在时优先于 `doc/<name>.cnx.partial`，所以走查 `.partial` 流程必须先在副本里移开
    成品文件，否则 `verify`/`assemble` 实际操作的是成品。
  - 文件权限归一：11 个文件此前是 `600`（`manifests/help_exemptions.json`、
    `tests/phase8/*`、`tests/phase9/test_native_catalog.py`、`tools/native_catalog.py`）、
    两个阶段入口 `tests/phase8/run.sh`、`tests/phase9/run.sh` 是 `711`。发布包按 tar
    原样保留权限，非属主用户解包后既读不了数据文件也执行不了这两个入口；现统一为仓库
    既有约定——数据/源码 `644`、入口脚本 `755`。

- 代码质量检查修复（2026-11-17）：
  - 保留诊断 formatter 返回 `nil` 的过滤语义；默认 virtual_lines 只翻译消息，保留诊断码。
  - 被外部 wrapper、nvim-tree 或已打开的 select 保留的回调，在模块/通道禁用及 teardown
    后停止翻译，继续保留原始回调的调用次数、返回值和外部函数所有权。
  - `NvimZhReload` 清理内置生成目录的 require 缓存，支持磁盘更新、加载失败回退及后续恢复；
    不清理用户 loader 的依赖缓存。
  - 缺失统计的路径脱敏支持纯中文、混合 Unicode、Windows/UNC 和相对路径。
  - Vimcdoc 健康检查排除本项目文档与符号链接别名，并要求外部中文帮助具有可用索引。
  - 在阶段 1–5 增加六份自动执行的回归规格，覆盖上述缺口及真实 extmark/float 渲染差分。

### Boundaries

- nvim-cmp 与外部工具没有安全公共接缝，保持 `inventory_only`。
- 不修改系统 locale、原始诊断/LSP 协议数据、quickfix 输入或外部工具字节流。
- Help 译文覆盖 manifest 中的全部 133 份用户文档（130 515 行源文）；另有 2 篇按证据
  排除（`credits.txt`、`uganda.txt`）。没有 `partial` 或 `not_started` 遗留，也不声称
  这 2 篇被翻译过。
- LSP 显示文本只覆盖固定源码中的字面量；协议字段、动态载荷、日志与服务器自定义
  消息保持原文。不声称“全部 LSP”。
- 核心消息：12 条上游标注 `# do not translate` 的条目保持英文，不声称译过；项目只维护
  译文资源与合并产物，**不自动安装、不替换**系统或 Neovim 自带 MO，宿主 locale、
  系统目录与 Neovim 本体均不修改。
- 核心消息：`make audit-native` 找不到运行时字面量的 15 条补充译文不声称已生效；
  另有上游已译但同样存在键不匹配的消息不在本轮改动范围，需上游目录修正。
