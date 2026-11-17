# 兼容性

验证日期：Help/插件矩阵 2026-11-14；核心消息目录 2026-11-14。只记录本机
Linux x86_64 的实际命令输出，不外推到其他平台。
下表是所列日期的历史测试记录；当前完整测试入口见 `README.md` 的「测试」。
真实服务器和真实上游 smoke 由显式环境变量开启。矩阵按当前 `make test` 范围（阶段 0–9）
重跑；运行时比对按 manifest 固定的 0.12.6 判定 pinned，规则见下文「版本差异与跳过规则」。

| Neovim | 状态 | 实际证据范围 |
|---|---|---|
| 0.12.6 / LuaJIT 2.1.1794386141 | 本机必过、已验证 | `make test`（阶段 0–9）全通过；`HELP_PARITY` 133 篇 0 问题；固定上游 smoke；可重复构建与发布清洁检查 |
| 0.11.5 / LuaJIT 2.1.1741730670 | 本机完整离线测试通过 | `make test NVIM_BIN=<0.11.5>`（阶段 0–9）全通过；该 runtime 缺 10 篇固定 0.12.6 文档，按 `upstream_absent` 跳过其运行时比对，上游 parity 打印 `HELP_PARITY=SKIP`（带篇数/tag 数分母）；下载包缺少中文 MO 且系统无 zh_CN locale，因此 E1 正向控制 SKIP；随包 `doc/tags-cn` 可解析，且对其重新 `:helptags` 生成的 `tags`/`tags-cn` 与随包文件逐字节一致（首行编码规则见下文） |
| nightly `0.13.0-dev-2081+g5a53f3bb9e` | 全量阶段 0–9 实测通过；仍仅预警 | `make test NVIM_BIN=<nightly>` 全通过；缺 `pi_zip.txt`（`upstream_absent`），上游 parity 按 pinned 跳过；pull 契约改用公开 in-process `vim.lsp.start()` client 生命周期；对该语料重新 `:helptags` 生成的 `tags`/`tags-cn` 与随包文件逐字节一致；不形成稳定兼容承诺 |
| 0.10.4 / LuaJIT 2.1.1713484068 | 仅基础能力通过 | `make test-foundation NVIM_BIN=<0.10.4>`：阶段 2 引擎/目录、setup/commands/native health、`.cnx`/`tags-cn`/英文回退通过；不声称完整 UI、插件、诊断或 LSP 支持 |

通过 GitHub latest release 实测 stable 为 0.12.6。0.11.5 对应上游 commit
`9fa7c0a04638ee3d5fefbdcec347b1c07a5ce9ce`（release API `target_commitish`；发布 tarball
SHA-256 `b2f91117be5b5ea39edd7297156dc2a4a8df4add6c95a90809a8df19e7ab6f52`）。
nightly 本次使用 2026-11-14 下载的 `0.13.0-dev-2081+g5a53f3bb9e`（2026-11-03 的
`6332ba64fe56f922c5cd2d93e4cfa23673966b6d` 记录仍保留在 `manifests/upstreams.json` 的
`validation` 中）；0.10.4 使用 `e96f75a4e60c9082e89c7f61e2ce0647e4ebdf43`。这些下载
均在临时目录，未替换系统 Neovim。

帮助文档的源文本固定为 Neovim 0.12.6：133 份 `complete` 文档的源文件、SHA-256 与译文
路径逐份记录在 `manifests/upstreams.json`，完整清单以 `manifests/help_inventory.json`
为准（该文件还为每篇 `complete` 译文记录由**固定上游**算出的 tag 集合、示例块序列与
`|链接|` 多重集摘要 `contract`），此处不再重复枚举。

译文契约因此分两层。**tag / 示例块 / `|链接|` / 文件尾部契约与 runtime 无关**：
`manifests/help_inventory.json` 的
`contract.tags_digest`/`blocks_digest`/`links_digest`/`tail_digest`（外加三个计数）由
`01_help_catalog_spec.lua` 在 pinned 守卫**之前**用 `vim.fn.sha256` 断言，**在所有
版本执行**——在 0.11.5/nightly 上删 tag、改示例块、动链接或改坏末行 modeline 同样
失败；`tests/phase8/test_help_inventory.py` 另有一项不读 `$VIMRUNTIME` 的交叉核对，
用生成该 `contract` 的同一套引擎重算每篇译文摘要并逐字段比对。**只有需要读运行中
`$VIMRUNTIME` 的比对**（逐篇源文件 hash、全文 parity、上游字面量、`:helptags` 再生成
相等）才对固定 0.12.6 成立，因为别的 runtime 本来就不带同一份英文原文；这些比对不把
不同 runtime 的文档伪装成该固定 hash，也不暗示文档内容已同步，固定 runtime 中不存在
的文档按 `upstream_absent` 明确跳过。

## Help 文档译文

每份 `complete` 文档的上游 repository、完整 commit、源文件路径、SHA-256、本地译文
路径与状态记录在 `manifests/upstreams.json`；逐篇覆盖状态记录在
`manifests/help_inventory.json`（由 `tools/help_inventory.py` 生成，phase8 校验其可
逐字节重建）。当前 135 篇 `runtime/doc/*.txt` 中：

| 状态 | 篇数 | 行数 |
|---|---|---|
| `complete` | 133 | 130 515 |
| `partial` | 0 | 0 |
| `not_started` | 0 | 0 |
| `excluded` | 2 | 1 002 |

133 篇正常用户文档已全部译完，没有 `partial`/`not_started` 遗留；其余 2 篇按证据排除
（`credits.txt`、`uganda.txt`），继续回退英文。
两篇 `excluded` 对象及其证据（`manifests/help_exemptions.json`）：

| 文档 | 排除理由 | 证据 |
|---|---|---|
| `runtime/doc/credits.txt` | 署名与版权记录，不是用户文档 | `:1` `*credits.txt*`；`:10` 作者与 `\|Bram-Moolenaar\|`；正文（`:12` 起）是贡献者姓名与致谢列表，不应翻译；`:113` 只在引用某外部源码时提到 license。此处**不出现** `\|manual-copyright\|`（该链接在 `uganda.txt:34`） |
| `runtime/doc/uganda.txt` | Charityware 募捐与 Open Publication License 条款 | `:7` 定义 `*uganda* *Uganda* *copying* *copyright* *license*`；`:33-:34` 指明许可证适用范围并 `\|manual-copyright\|`，翻译会改变法律措辞 |

全部固定上游 commit `779c36969e31080503be2dfccbcc3f999e289606`。`make test-phase8`
在 0.12.6 上实际比较运行时的 `$VIMRUNTIME/doc/*.txt` 与 manifest 中的 hash，并验证 tag
双向一致、示例块与 `|链接|` 不变、术语符合 glossary、`doc/tags`/`doc/tags-cn` 与
Neovim 自身 `:helptags` 输出一致、`:help <文档>` 打开中文且未翻译文档仍回退英文。
其他 Neovim 版本验证 `:help` 选择、英文回退、tags 与文档的双向引用一致、13 个抽样
tag 可解析，以及上面那组由 manifest 摘要驱动的 tag/示例块/链接契约，不断言 hash。

### 版本差异与跳过规则

`make test-phase8` 分两层。**译文契约层与 runtime 无关**：每篇 `complete` 译文的
tag 集合、示例块序列、`|链接|` 多重集与文件尾部（末行 modeline 及其后的全部字节）
在 `manifests/help_inventory.json` 的 `contract` 里存有由固定上游算出的 sha256 摘要
（`tags_digest`/`blocks_digest`/`links_digest`/`tail_digest` 与三个计数），
`01_help_catalog_spec.lua` 在 pinned 守卫**之前**用 `vim.fn.sha256` 断言
它们，因此删一个 tag、改一个示例块、动一个链接或改坏末行 modeline 在**所有版本**
（含 0.11.5/nightly）都会失败，而不是只在 0.12.6 失败。同一批值还会被
`tests/phase8/test_help_inventory.py` 用生成它们的那套引擎重算后逐字段比对，这一项
不读 `$VIMRUNTIME`，同样在所有版本执行。

**runtime 比对层只在 pinned 成立**：需要读运行中 `$VIMRUNTIME` 的断言只对 manifest
固定的 0.12.6 有意义，因为其他版本的英文原文本来就不同。具体规则：

- 固定 runtime 中**不存在**的文档：`HELP_CATALOG_SPEC` 把该篇标为 `upstream_absent`
  并跳过它的运行时比对。0.11.5 缺 10 篇（`api-ui-events`、`dev`、`dev_test`、
  `l10n-arabic`、`l10n-hebrew`、`l10n-russian`、`l10n-vietnamese`、`news-0.11`、`pack`、
  `plugins`），nightly `0.13.0-dev-2081+g5a53f3bb9e` 缺 `pi_zip.txt`，0.12.6 缺 0 篇。
  该篇的译文契约仍照常断言，只是不与运行时英文原文比对。
- 全文 parity：`check_help_parity.py` 打印
  `HELP_PARITY=SKIP pinned=0.12.6 runtime=… documents=133 tags=10798
  translation_contract=checked_by_01_help_catalog_spec` 并以 0 退出，而不是拿 0.12.6
  译文与别的 runtime 逐字节对比（0.11.5 的 `deprecated.txt` 是 `*deprecated-0.11*`，
  pinned 基线是 `*deprecated-0.12*`）。SKIP 行给出被跳过的**分母**；宣布 pinned 之前
  还会先用 manifest 的 sha256 抽查实际 runtime 的首/中/尾三篇文档（`probe_documents()`），
  避免仅凭 `--version` 自报版本、或只碰巧带对第一篇文档就被当成基线。
- 上游字面量（`02_lsp_ui_text_spec.lua`）：`pinned=false` 时跳过「msgid 仍存在于上游
  源码」的检查（0.11.5 没有 `document_color.lua`，`codelens.lua` 文案也不同），插件
  自身译文契约照常执行（实测 `notify=15 prompts=3 pinned=false`）。
- `doc/tags`、`doc/tags-cn` 与 `:helptags` 再生成的逐条相等只在 pinned 断言：这是
  「索引是否等于该生成器的输出」。跨版本另有与 runtime 无关的守卫：
  `test_shipped_tags_are_internally_consistent`（`tags-cn`/`tags` 与 `doc/*.cnx`、
  `doc/*.txt` 双向一致：索引条目必须指向存在且确实定义了该 tag 的文件，文件里定义的
  tag 必须出现在索引里）、`03_help_parity_rules_spec.lua`（**两个索引文件**的每一行都
  按 `:helptags` 的转义规则重建第三列搜索模式，写错即在所有版本失败）、
  `test_first_lines_share_one_encoding_class` 与
  `test_helptags_regeneration_is_not_destructive`（见下一节）。13 个抽样 tag
  （含 `E767`、`[q`、`quote:`、`uv.pipe_chmod()` 这类特殊字符 tag）在 0.11.5 上实测
  全部命中正确 `.cnx`，`credits` 仍回退英文。
- pinned 分类是显式的：`version == manifest.version` 才算 pinned；**自报固定版本但
  `vim.version().prerelease` 非空的构建**（如 `0.12.6-dev`）直接报错
  `pinned/unpinned cannot be decided`，而不是静默降级为 unpinned 跳过全部 runtime
  比对。0.11.5/nightly 的 `pinned=false` 来自版本不同，不受此规则影响；Lua spec 的
  版本一律从 manifest 推导，不再各自硬编码。
- `tests/phase8/test_help_inventory.py` 只有两项依赖运行中的 `$VIMRUNTIME`（清单再
  生成、语料覆盖）在非 pinned 版本跳过；其余（inventory ↔ manifest ↔ exemptions 一致、
  status/topic/priority 枚举、totals 算术、excluded 证据、`contract` 字段完整性，以及
  用同一套引擎重算出来的 `contract` **取值**与随包译文是否一致）在所有版本执行。

### `:helptags` 的首行编码规则（0.10/0.11 专有陷阱）

Neovim 0.10/0.11 的 `src/nvim/help.c`（`helptags_one()`）**只看每个文件的首行**判定
编码：首行含非 ASCII 字节即为 utf-8，纯 ASCII 即为 latin1；同一语言目录里两种混用时
抛 `E670: Mix of help file encodings within a language`，**中止该语言且不写任何条目**
——进程仍以 0 退出，随包的 `doc/tags-cn`（10 798 条）会被重写成一个空文件。0.12 已删除
这段检查（`help.c` 中不再有 `E670`，也不再写 `!_TAG_FILE_ENCODING`），所以混用只在
0.10/0.11 上失败。

修复不是绕开，而是回到翻译契约第 10 条「首行 `*<name>.txt*` 头逐字节照抄上游」：
133 篇译文的首行现全部逐字节等于其上游 ASCII 标题行，第 134 篇 `doc/nvim-zh.cnx`
是插件自有帮助、首行同为 ASCII；中文标题另起一行。因此 0.11.5
上的 `:helptags` 重新生成与随包 `doc/tags-cn`、`doc/tags` **逐字节一致**，上述破坏性
场景不再可能。三条守卫把这一点钉死：`test_first_lines_share_one_encoding_class`
（首行必须 ASCII）、`test_helptags_regeneration_is_not_destructive`（再生成不得报
`E670`/`E15x`，且 `tags-cn` 不得被截断）、`test_shipped_tags_are_internally_consistent`
（索引 ⇄ 文档双向一致）；`tests/phase6/test_maintenance.py` 的结构断言保证它们不会被
删除。

## 固定上游与公共接缝

| 插件/能力 | 固定版本 | 实测结果与边界 |
|---|---|---|
| which-key | `3aab2147e74890957785941f0c1ad87d0a44c15a` | 真实 smoke PASS；`replace.desc` 与正常 setup 后重挂；mapping 不变 |
| Telescope | `40aedd8a68c78a656a10a8d62d80c54af59420fb` | 真实 smoke PASS；picker/静态/动态 previewer 标题；entry/previewer 数据不变 |
| Plenary（测试依赖） | `74b06c6c75e4eeb3108ec01852001636d85a932b` | 真实 Telescope smoke 使用 |
| lazy.nvim | `306a05526ada86a7b30af95c5cc81ffba93fef97` | 真实 smoke PASS；共享 `vim.notify` 与 `User LazyLoad`；不碰私有 view |
| nvim-tree | `69eb0c34ed3d836d5a0d92d913b77dd73b054f2f` | 真实 smoke PASS；公开 setup/on_attach mapping desc；lhs/rhs/buffer 不变 |
| nvim-cmp | `2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3` | 真实复审 PASS，继续 `inventory_only`；三个固定源码 hash 匹配 |
| clangd | 固定 smoke `llvmorg-23.1.4`（Arch `23.1.4-1`）；系统 `23.1.5-1` | 真实 push smoke PASS；标准化 pull 不受该服务器支持；仅 4 条静态规则 |
| 外部工具 | 不适用 | 固定 fixture 原始字节不变；无安全公共显示接缝，继续 `inventory_only` |

nvim-cmp 的固定 `formatting.format` 只是 `return vim_item`；`entry.lua` 中的 abbr/kind/menu
来自补全 entry/source 数据，不是 cmp 自己拥有的固定标签。因此没有包装 formatter，也没有
新增 domain 或开关。证据为固定源码 `lua/cmp/config/default.lua` 第 53–56 行与
`lua/cmp/entry.lua` 第 381–384 行；SHA-256 均记录在 manifest。

## clangd 实测与分母

未修改系统安装。固定 smoke 使用 Arch 官方固定包在 `/tmp` 解压的
`clangd version 23.1.4`（`linux x86_64-pc-linux-gnu`），上游 commit
`7a941dfb2877a0b8cf30323fefa85ad019e0b0f5`。本机 PATH 现在也有 clangd
（`/usr/sbin/clangd`，`clangd version 23.1.5`，包 `clang 23.1.5-1`）；用它对同一阶段
的固定 corpus 复跑，`static=4`、`corpus=5/7`、`runtime=12/18`、`push=6/6` 全部一致。
命令为：

```bash
LD_LIBRARY_PATH=<临时工具链>/usr/lib \
NVIM_ZH_TEST_CLANGD=<临时工具链>/usr/bin/clangd \
make test-phase7
```

固定 corpus、原始 push 诊断（message/code/source/range/relatedInformation）、pull 错误、
initialize 能力、包与 corpus SHA-256 保存在 `tests/phase7/`。结果分别为：

- 静态目录：**4 entries**（原 2 条 + 真实观察的 undeclared identifier、unknown type name）。
- 固定 corpus：**5/7 唯一消息**（含 relatedInformation）；两个 `Expected ...` 消息安全回退。
- 主诊断运行时：**4/6**（固定 corpus 的 6 条唯一 push 消息中 4 条被译，另 2 条 `Expected ...` 安全回退原文）；formatter 实际调用（含 virtual_text/virtual_lines）为 **12/18**（= 4 × 3 条显示接缝）。
- 真实服务器 push：**6/6 收集，原始数据不变**。
- 真实服务器 pull：`textDocument/diagnostic` 返回 LSP `-32601 Method not found`，initialize
  也未声明 diagnosticProvider；状态为 `unsupported_method_not_found`，不是 PASS。离线公开
  handler 契约仍分别验证 push/pull 的原文与协议元数据不变。

这些数字不是“全部 clangd”或“全部 LSP”覆盖率。

## 核心消息目录（native catalog）

2026-11-14 在本机 Arch Neovim 0.12.6（`/usr/sbin/nvim`，二进制 SHA-256
`d308f10e416aec90c8794a7a10174777b8262076fc9d5aa3db043fd86e260531`）实测。
固定上游目录 `src/nvim/po/zh_CN.UTF-8.po`（commit `779c3696…`，SHA-256
`c653446d8b3eb572b81682f6b7b6975f87de92937d5f11546e1b5efa85aea308`，295 080 字节）
共 1985 条消息：1855 条已译、130 条未译。

| 项目 | 条数 | 结果 |
|---|---|---|
| 本项目补充译文 | 118 | `translations/native/zh_CN.po`；覆盖率、占位符序列、错误码、术语、UTF-8 全部通过 |
| 上游 `# do not translate` 豁免 | 12 | 保持英文；逐条 marker 与理由在 `manifests/native.json` |
| 重建运行时 msgid（截断修复） | 4 | `E5403/E5404/E5405/E5406`，按固定上游 C 源码重建 |
| 补带 `E###: ` 前缀的运行时键 | 25 | `E574/E575/E576/E886/E136` 调用点；证据为该二进制中的字面量 |
| 合并后 MO | 2014 条 | 2002 translated / 12 untranslated（等于豁免数），`msgfmt` 统计一致 |

`make build-native` 产出的 MO 在临时 prefix（复制 nvim 二进制 + 临时 `zh_CN.UTF-8`
locale + `LOCPATH`）下实测，宿主 locale、系统目录与 Neovim 本体均未改动：

| 触发 | 只有上游目录时 | 加入本项目补充后 |
|---|---|---|
| `:call writefile([…], "/proc/nope/f")` | `E482: Can't open file … for writing` | `E482: 无法打开文件 /proc/nope/f 进行写入：no such file or directory` |
| 损坏的 `main.shada` 启动 | `E576: Error while reading ShaDa file: last entry …` | `E576: 读取 ShaDa 文件时出错：最后一个条目声明占用 114 字节，但文件提前结束` |
| 损坏 shada 时重命名失败 | `E136: Did not rename …` | `E136: 未重命名 …，因为 … 看起来不像 ShaDa 文件` |
| `msgpackdump` 自引用字典 | 英文 | `E5005: 无法 dump msgpackdump() 参数，索引 0：容器在 键 'self' 中引用了自己`（用到本项目的 `key %s` 片段译文） |
| 豁免条目 `[Command Line]` | 英文 | 仍为英文（上游标注不译） |

上表每一行都由 `NVIM_ZH_TEST_NATIVE_RUNTIME=1 make test-phase9` 在临时 prefix + 临时
locale 下断言（`E136`/`E5005` 与豁免行过去只是文档声明、没有测试覆盖）；同一测试还会用
缓存的固定上游 PO 重建 MO，并断言它与随包 `build/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo`
逐字节相同。

机器可读审计在 `build/native/audit.json`。118 条补充的运行时对位结果是：

| 分类 | 条数 | 含义 |
|---|---|---|
| `bare` | 76 | 二进制中存在同文字面量（无前缀） |
| `bare_and_prefixed` | 25 | 另有带 `E574/E575/E576/E886/E136` 前缀的调用点，已由 `prefix_repairs` 补条目 |
| `prefixed_only` | 0 | 只找到带 `E###: ` 前缀的调用点、没有无前缀同文字面量 |
| `runtime_file` | 2 | 字面量在 `runtime/scripts/optwin.lua` 等运行时文件中，不在二进制里 |
| `unverified` | 15 | 在二进制与 runtime 树中都找不到字面量；**不声称**已生效 |

15 条未对位项中有 4 条可确认是上游 po 措辞过期（键永远命不中），证据逐条记录在
manifest 的 `runtime_audit.stale_upstream_msgids`：

| 上游 po msgid | 运行时字面量 |
|---|---|
| `E5100: Cannot convert given lua table: …` | `E5100: Cannot convert given Lua table: table should contain either only integer keys or only string keys` |
| `E5101: Cannot convert given lua type` | `E5101: Cannot convert given Lua type` |
| `E5114: Error while converting print argument #%i: %.*s` | `E5114: Converting print argument #%i: %.*s` |
| `  --server <address>    Specify RPC server to send commands to\n` | `--server <address>    Connect to this Nvim server\n` |

这类需要上游更新 po（或由项目另立运行时键条目），本轮不擅自改写上游 msgid；同样
性质的过期键若存在于上游已译条目中，同样需要上游修正。二进制与补充条目的对应关系
是版本相关的：换 Neovim 版本必须重跑 `make audit-native` 并复核 manifest。

```bash
make check-native                               # NATIVE_CHECK=PASS
make sync-native                                # NATIVE_SYNC=PASS（显式联网）
make build-native                               # NATIVE_BUILD=PASS mo_sha256=…
NVIM_ZH_TEST_NATIVE_RUNTIME=1 make test-phase9  # 15 tests OK（运行时探针 + 随包 MO 重建相等）
```
