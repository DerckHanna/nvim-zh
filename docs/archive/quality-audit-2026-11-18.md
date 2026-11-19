# nvim-zh 全量质量审计报告

[现行验证记录](../verification.md)

日期：2026-11-18。工作目录 `/home/hanna/desktop/nvim-zh`。分支 `main`，接手 HEAD `e516445`。
本次**未提交、未推送、未打 tag、未发布**；未操作用户已安装插件、真实 Neovim 配置、系统 Neovim/MO/locale。
所有实机测试使用独立临时 XDG/日志/TMP 与测试安装；固定上游研究源码全部在仓库外，不进发布包。

**证据归档（仓库外）**：`nvim-zh-audit-evidence/`
- `upstreams/` — manifest 固定上游源码（sha256 全部校验）
- `renders/` — 真实 nvim PTY 会话 cell grid（`.json`）、原始字节流（`.raw`）、真实字体渲染（`.png`），56 个场景
- `reports/` — 逐域/逐批审校报告、缺陷登记、扫描结果、Help 遍历记录
- `logs/` — 全部 Make/测试/parity 执行日志
- `env/` — 独立 XDG 配置、渲染 venv、Consolas+微软雅黑字体
- `work/` — 修改前原件备份、抽查取证

---

## 0. 结论速览

- **译文质量审查**：5 个生产 domain（410 条）+ native（132 条）逐项人工语义审校完成；133 篇上游 Help 由 6 个审校批次覆盖（散文逐段全审，超大 API 参考系统抽查并如实声明未逐句范围）。
- **发现并修复确认缺陷**：运行时/适配器缺陷 5 个（BUG-01…05）+ 译文缺陷若干（详见 §2 统计口径）。
- **实机英文残留**：按 A/B/C/D/E 分类（§3）；A/B 类已修复，C/D 为有意保留并说明理由。
- **中文排版**：quickref 目录表对齐、intro 欢迎页居中、超宽散文重排已修复并实机前后对照（§4）。
- **门禁**：Makefile 全部适用检查 + 固定上游 test-upstream + 真实 native/clangd + 新增实机矩阵，**全部 PASS**（§6/§8）。
- **验收条件**：具备本次审计验收条件；剩余为上游源文问题、项目级术语决策与未验证平台（§7），均有明确边界。

### 修复统计口径
- **运行时/适配器缺陷**：5 个（BUG-01 which-key 默认流程、BUG-02 quickref 对齐、BUG-03 引号漂移 4 键、BUG-04 默认映射描述 19 条、BUG-05 Telescope 首开），全部实机复验 + 新增 2 回归测试。
- **domain/native 译文缺陷**：which-key 1+风格、telescope 2、nvim-tree 2、nvim-ui 1、native 3 Required+4 风格，全部采纳修复。
- **Help 确认缺陷**：6 批合计 Required 57 + Optional 56；Required 全部修复，Optional 除少数上游源文问题（H3-05/H3-11 等，译文忠实上游）外全部修复。Nit/风格约 160 项，采纳一致性收尾，术语级留待项目决策。
- **改动规模**：58 篇 Help `.cnx`、7 个 PO、2 个运行实现（plugins.lua/telescope.lua）、2 个工具（native_catalog.py/resource_bundle.py）、manifest、6 个测试文件 + 2 个新增回归测试；生成物经工具重建。
- 统计口径：按「确认缺陷条目」计（非行数）；批量同类（如 WK-06 空格 22 条、H1-10 元数据 219 处）在各自编号下归并。

> 重要声明：自动检查通过 ≠ 全量语义审校通过；目录条目命中率 ≠ 整体汉化率。本报告严格区分五种完成状态（§1.1），未把抽查说成全量，未宣称整个 Neovim/第三方插件/clangd 已全部汉化。

---

## 1. 审计范围与方法

### 1.1 五种完成状态的区分（不互相替代）
| 状态 | 含义 | 本次覆盖 |
|---|---|---|
| 自动规则检查 | 占位符/术语/保护片段/结构 parity 机械校验 | 全量 |
| 人工语义审查 | 结合英文原文、上下文、调用方逐条/逐段审 | domain/native 全量；Help 散文全量+参考抽查 |
| 固定源码核对 | msgid/接缝与 manifest 固定 commit 源码逐字比对 | 全量（sha256 校验）|
| 实机流程执行 | 真实 nvim + 固定上游插件在独立 XDG 执行用户流程 | §5 矩阵 |
| 实际画面检查 | 真实 PTY 终端协议会话渲染 grid 检查（含真实 CJK 字体 PNG）| §4/§5 |

### 1.2 实机环境
- Arch Linux WSL2，内核 6.18.58.1-microsoft-standard-WSL2，x86_64，glibc。
- Neovim v0.12.6 RelWithDebInfo，LuaJIT 2.1.1794386141（`/usr/sbin/nvim`）。
- clangd 23.1.5（`/usr/sbin/clangd`）；Python 3.12.15；GNU gettext msgfmt。
- 终端：POSIX PTY + pyte VT 仿真，`TERM=xterm-256color`，`COLORTERM=truecolor`；字体 Consolas（ASCII）+ 微软雅黑（CJK）。
- **真实 GUI 终端截图 BLOCKED**：无 xterm/alacritty/kitty 等终端模拟器，无 X 库，sudo 被 `no_new_privs` 阻止，pacman 缓存无 X/字体包。改用真实 nvim PTY 会话记录终端 cell grid 并以真实字体绘制 PNG。这是真实 Neovim 在真实终端协议会话中的渲染（nvim 查询终端、driver 应答能力查询、resize 走真实 TIOCSWINSZ+SIGWINCH），**不是 headless 文本 dump，但也不是 OS 窗口截图**——如实区分。

### 1.3 固定上游（`manifests/upstreams.json` 为准，已下载并 sha256 校验）
- neovim 0.12.6 `779c36969e31080503be2dfccbcc3f999e289606`；133 篇 Help sha256 全匹配。
- which-key `3aab2147`、telescope `40aedd8a`、lazy `306a0552`、nvim-tree `69eb0c34`、nvim-cmp `2ffe79f1`、plenary `74b06c6c`。
- clangd llvmorg-23.1.4 `7a941dfb`。
- 56 个 manifest source 文件 + 6 个 nvim-ui lsp 源 + errors.h/testing.c/tui/bufwrite/ex_getln/converter/executor/main/fileio 源 sha256 全部匹配（`reports/fetch_upstreams.json`）。

### 1.4 生产 domain 与条目（`catalog.lua` BUILTIN_SOURCES 为唯一真源）
nvim-ui(18) which-key(195) telescope(96) nvim-tree(97) clangd(4) = **410 条**编辑源（审校后）。
native：zh_CN.po(118 supplement) + runtime_repairs.po(8) + intro.po(6) = 132 条；合并 MO 2024 条（2012 译 / 12 豁免）。
Help：133 篇上游 `.cnx` + 项目自有 `nvim-zh.cnx/.txt`。

> 计数口径说明：任务简报按 PO `msgid` 行计（含头部空 msgid），审校按 `msgfmt` 可译条目计。which-key 176→195（新增 19 条 Neovim 默认映射描述，BUG-04）；telescope 96；nvim-tree 97；nvim-ui 18；clangd 4。

---

## 2. 译文质量问题及修复

### 2.1 运行时/适配器缺陷（实机发现，5 个）

| 编号 | 严重度 | 类别 | 问题 | 修复 | 验证 |
|---|---|---|---|---|---|
| BUG-01 | 高 | A 已有译文未命中 | which-key 默认启动流程描述全英文：which-key 经 500ms timer 自动 setup，晚于 nvim-zh setup，签名不变致补检不触发 | `plugins.lua` 增加启动后有限次延迟补检（300/800/1600ms，签名变化才 re-attach，teardown 清理）| 实机无焦点事件 `g` 弹窗中文；新增 `startup_late_attach_spec.lua` PASS；幂等 desc_len=9 |
| BUG-02 | 中 | 中文排版 | quickref.cnx 目录表第二列错位（CJK 双宽改变制表符停位，24/32/40 参差）| 仅调整每行制表符数使第二列统一显示列 40（表头 41，与英文一致）；`git diff -w` 为空 | 实机 18 行第二列均=40；parity PASS |
| BUG-03 | 中 | A 已有译文未命中 | E15/E856/E1115/E1116 上游 PO 抽取丢引号，运行时带引号键永不命中 | `runtime_repairs.po` 增 4 条运行时精确键；`native_catalog.py` 最小扩展 quote_drift 校验；manifest 记录 evidence | 实机 `:echo 1 +`→「E15: 无效的表达式："1 +"」；MO 四键有译文 |
| BUG-04 | 中 | B 接缝缺目录 | Neovim 默认映射描述（CTRL-W d/D 诊断、gc 注释、]n/[n 节点等 19 条）经 replace.desc 显示但缺目录 | which-key.po 增 19 条 desc，source 指向固定 defaults.lua | 实机「显示光标下的诊断」「切换注释」中文；check-translations PASS |
| BUG-05 | 中 | A 时序未命中 | Telescope 会话首个 picker 标题英文：window/previewer 模块首次 pickers.new 内才加载，create_layout 已用未包装函数 | `adapters/telescope.lua` 在固定上游 `User TelescopeFindPre` 公开边界 sync（attach 幂等、teardown 删除）| 实机首开 find_files=结果/查找文件；新增 `telescope_first_picker_spec.lua` PASS |

### 2.2 逐域审校缺陷（人工语义审查）

| domain | 审校条数 | 确认缺陷 | 修复 |
|---|---|---|---|
| which-key | 176（审校时）| WK-01 source ref 误标（低）；WK-02 主体偏移、WK-04 缺中心语、WK-06 中英空格 22 条（风格）| WK-01 改 config.lua 引用；WK-02/04/06 采纳；WK-03/05 保留（忠实上游/社区接受）|
| telescope | 96 | TS-01 Buffer 空格 5 条、TS-02 Packages→Lua 包（Required）| 全部采纳 |
| nvim-tree | 97 | NT-01 Copy Basename→复制主文件名（Required）、NT-02 Rename: Basename（Optional）| 采纳；同步 upstream smoke 夹具 |
| nvim-ui | 18 | UI-01 Rename 增译「失败」（Optional）| 采纳；同步 lsp_literals_spec |
| clangd | 4 | 无 | — |
| native | 132 | NV-01 E5602 float=浮动窗口（领域错译）、NV-02 partial self dictionary、NV-03 msgpack buffer≠缓存（Required×3）；NV-04 intro 居中、NV-05 optimize、NV-06 buffered stream、NV-07 条件语气（风格×4）| 全部采纳；intro 六行等宽=44 |

### 2.3 Help 逐批审校缺陷（6 批，133 篇）

| 批次 | 篇数 | 覆盖 | Required | Optional | Nit | 修复状态 |
|---|---|---|---|---|---|---|
| 0 | 20 | 19 full + vimfn sampled-140 | 6（中）| 6（低）| 11 | Required 全修；Optional 全修；Nit 部分（节标题/冒号/空格）|
| 1 | 21 | 19 full + options sampled-88 + quickref sampled-104 | 13 | 18 | 48 | Required 全修；Optional 全修；H1-10 options 元数据 187+32 处规范化 |
| 2 | 24 | 23 full + syntax sampled | 12 | 4 | 6 | Required 全修；Optional 全修 |
| 3 | 23 | 19 full + lua/lsp/quickfix/treesitter sampled | 3 | 10 | 1 | Required 全修；Optional 修 8（H3-05/11 为上游源文问题，保留）|
| 4 | 23 | 18 full + api/vimeval/map/pattern sampled | 11 | 8 | 48 | Required 全修；Optional 全修（含 dev_tools 16 标题、mbyte 编码表 63 行）|
| 5 | 22 | 17 full + luaref/luvref/spell/starting/gui sampled | 12 | 10 | 47 | Required 全修；Optional 全修；fence 标记全库修复 |

**Help 确认缺陷合计**：Required 57 + Optional 56（其中 H3-05/H3-11 等少数为上游源文问题，译文忠实上游，按纪律保留并报告）。Nit/风格建议约 160 项，采纳其中一致性收尾（节标题、冒号、空格、fence），其余术语级建议留待项目决策（§7）。

**典型修复举例**（每项含位置/原文/原译/修正/理由，详见各批报告）：
- H0-01 nvim.cnx:68 主客倒置（provider 文档≠软件）→「要使用某些功能，你可能需要额外安装软件，见…」
- H1-08 options 'allowrevins' 误按方向反 →「想按 SHIFT-_ 却误按了 CTRL-_」
- H2-01 change.cnx `:s///c` 确认键列表 8 行整段缺失 → 补回 y/l/n/Esc/a/q/CTRL-E/CTRL-Y
- H2-05 index.cnx 方括号命令 [D/[I/[d/[i 等丢失「#define/匹配光标下单词」核心语义 → 按 EN 补全 14 条
- H3-02 usr_29 命令拼写颠倒 `}]`→`]}`；H3-03 `[#` beep 条件方向反
- H4-12 usr_11 E325 三条件 AND 误作 OR →「同时满足」
- H4-51 pattern `\@!` 例句否定丢失；H4-52 `\@<=/\@<!` behind 方向反 →「前方」
- H5-01 userfunc [!] unless 条件反转；H5-12 starting bisect 第 4 步算法错 →「被移除行中的一半」
- H5-05 lua-guide 4 处 fence `>vim` 被改 `>lua` → 恢复；全库 fence 比对另修 vvars 10 处、usr_25 2 处

### 2.4 修复纪律
- 每项修正结合原文、上下文、调用方与真实界面，非词典匹配或批量替换。
- 上游 Help 译文只针对已确认问题逐项修正；示例块/tag/链接/命令/快捷键/路径/协议对象不动（parity 全量 PASS 证明）。
- 术语 Buffer/Window/Register preserve；禁词「缓冲区/窗口/寄存器」0 命中。
- 占位符（%s/%d/%i/%.*s/%zu/%<PRIu64>/%<PRIdVARNUMBER>/{name}）数量顺序类型保持。
- 生成物（catalogs/generated、resources、MO、merged.po）经工具重建，未手改。

---

## 3. 英文残留分类与未覆盖边界

实机矩阵（`reports/live-matrix-grids.json`，46 场景，英文基线 vs 中文启用对照）：

| 类别 | 含义 | 实例 | 处置 |
|---|---|---|---|
| **A** 已有译文未命中 | 目录有但运行时未触发 | BUG-01 which-key 默认流程、BUG-03 引号漂移、BUG-05 首开 picker | **已修复** |
| **B** 接缝缺目录 | 有安全接缝但缺条目 | BUG-04 Neovim 默认映射描述 | **已修复** |
| **C** 有意保留技术文本/用户数据 | 内部行为值、代码、路径 | Telescope 内部 prompt_title（Live Grep/LSP Dynamic Workspace Symbols）、诊断码 [undeclared_var_use]、vim.lsp.buf.*() 映射描述、:help *-default、文件路径、寄存器内容 | 保留（refine 判断依赖英文行为值，实测 refine 功能正常）|
| **D** 无安全接缝的已知边界 | 私有 UI/动态标题 | which-key footer（close/back/scroll）、Telescope refine 最终 `border:change_title`（Find Word (setup)/LSP Workspace Symbols (main)）、nvim-tree 私有 renderer/help Buffer、nvim-cmp inventory-only、E1568 DSR 警告（defaults.lua vim.notify，非 gettext）| 保留并说明（docs/adapters.md 已声明；refine 边界证据 `reports/refine-boundary-evidence.json`）|
| **E** 尚未执行/证据不足 | 未触发的流程 | clangd 真实 $/progress（本机 clangd 未发进度事件，见 §7）、showMessageRequest 实机 coroutine yield | 契约测试覆盖；实机标 BLOCKED/未完成 |

**局部漏译检查**：不只搜整行 ASCII——中文句内嵌英文（如「Git Buffer提交」缺空格、「当前Buffer没有」）已由 TS-01/WK-06 修复；混合行逐条审校。

**clangd 诊断显示**（真实 clangd 23.1.5）：
- float：「使用了未声明的标识符 'undeclared_var'」，诊断码保留英文。
- virtual_text（setup 前启用）：「■ 使用了未声明的标识符 'undeclared_var'」。
- virtual_lines：「└──── undeclared_var_use: 使用了未声明的标识符 'undeclared_var'」。
- 原始诊断 message/source=clang/code/user_data.lsp 不变（`work/clangd-raw-check.json`）；quickfix text 保留原文。
- 用户 formatter nil 隐藏语义保留（`work/formatter-nil.json`）。

---

## 4. 中文布局问题及实机前后证据

### 4.1 已修复
| 问题 | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| BUG-02 quickref 目录表第二列 | 显示列 24/32/40 参差 | 18 行统一列 40（表头 41）| `renders/final-quickref/`、`renders/layout-help/help-table-120x40.png` |
| NV-04 intro 欢迎页居中 | 各行宽 36–43，起始列 18/20/22 错位最多 4 列 | 六行等宽=44，起始列统一 18 | `renders/final-intro/final-intro.png` |
| 超宽散文（gui/helphelp/vimeval/usr_29）| 102–162 列单行 | 按 tw≈78 重排 | parity PASS；help wrap=true 实机可读 |

### 4.2 排版矩阵（`reports/layout-matrix-grids.json`，45 网格，0 乱码/替换字符）
- 尺寸：120×40、80×24、60×20、40×12、28×10、200×50；连续 resize（28→120→60→200→80）。
- 面板：窄尺寸 ellipsis 截断整齐，无半宽 CJK、无越界（0 overflow 行）；resize 后焦点/光标正确（cursor={1,0}）；切页/搜索/滚动/配色变化稳定；关闭后 0 残留 window/autocmd。
- Help：133 篇真实 Help Buffer 遍历全部加载 `.cnx`（`reports/help-traverse.json`，0 问题）；正文/标题/列表/表格显示正常。
- 适配器：which-key/Telescope 窄尺寸弹窗中文正常。

### 4.3 超宽行分类（`reports/help-wide-classified.json`）
- 全库 >90 列散文行 224 行；其中**上游本身超宽**（URL/API 签名/表格，en_max>90）占多数，属允许横向滚动内容，不改。
- **中文引入超宽**（en_max≤90）34 行：gui/helphelp/vimeval/usr_29 已重排；其余 27 行为 91–99 列轻度超宽，help `wrap=true` 自然换行可读、无截断，记录为接受。
- 不以统一截短/重排示例/删内容"解决"溢出。

---

## 5. 已执行流程、尺寸与版本矩阵

### 5.1 实机用户流程（真实 nvim + 固定上游，独立 XDG）
| 流程 | 英文基线 | 中文启用 | 结果 |
|---|---|---|---|
| 欢迎页 | type :help… | 输入 :help…（六行等宽）| PASS |
| native 错误（E492/E212/E15）| 英文 | 中文 | PASS |
| notify/notify_once | No information available | 没有可用的信息 | PASS |
| input/select prompt | New Name:/Code actions: | 新名称：/代码操作： | PASS |
| :NvimZh 四页（有/无数据、降级、待重启）| — | 中文 | PASS |
| :NvimZhCheck / :checkhealth nvim-zh | — | 中文 | PASS |
| 中文 Help 选择 + credits 英文回退 + @en | — | cnx 选择/英文回退 | PASS |
| which-key presets/marks/registers/spelling/count/通知 | 英文 | 中文（默认流程、晚加载、重 setup）| PASS |
| which-key 自定义描述碰撞 | — | 同 msgid 显示译文（ documented 边界）| PASS（边界确认）|
| Telescope 已适配 picker 标题/preview/Live Grep/refine | 英文 | 中文（首开+后续）；refine 内部英文保留 | PASS |
| nvim-tree 默认 on_attach/lazy 先 setup 后 LazyLoad/已有 Buffer | 英文 | 中文；已有 Buffer 不改写 | PASS |
| clangd virtual_text/virtual_lines/float/quickfix/user_data.lsp | 英文 | 中文显示，原始数据不变 | PASS |
| 实现更新待重启 / 纯资源更新免重启 | — | 重启提示 / 直接生效 | PASS（副本仓库实机）|

### 5.2 尺寸矩阵
120×40、80×24、60×20、40×12、28×10、200×50 + 连续 resize + 打开后缩小/放大。

### 5.3 版本
Neovim 0.12.6（固定基线）；which-key/telescope/lazy/nvim-tree/nvim-cmp/plenary/clangd 均 manifest 固定 commit。其他版本未验证（§7）。

---

## 6. PASS / FAIL / SKIP / BLOCKED

| 检查 | 结果 | 说明 |
|---|---|---|
| make check-syntax | PASS | py=30 sh=10 lua=101 |
| make check-translations | PASS | 5 domains / 410 entries |
| make check-native | PASS | gaps=130 supplement=118 exemptions=12 repairs=8 prefix_repairs=25 intro=6 |
| make build-resources / check-resources | PASS | 145 文件确定性 |
| make check-reproducible | PASS | generated_lua native_mo complete_resources |
| make test（unit/contract/tools/integration/e2e）| PASS | 含新增 2 回归测试 |
| make test-upstream（6 固定源码变量）| PASS | 52 接缝文件 + plenary |
| NVIM_ZH_TEST_NATIVE_RUNTIME=1 test-integration/e2e | PASS | 真实 MO 消息 + 中文欢迎页 |
| NVIM_ZH_TEST_CLANGD test-integration | PASS | push=6/6 pull=unsupported_method_not_found corpus=5/7 raw=unchanged |
| make release-check | PASS | 465 文件，仅排除 .git |
| tools/help_parity.py（固定 runtime）| PASS | documents=133 problems=0 |
| 新增实机语言/排版矩阵 | PASS | 46+45 网格，0 乱码 |
| 默认 test 中 real clangd | SKIP | 未设路径（显式开启后 PASS，不混计）|
| 真实 GUI 终端截图 | BLOCKED | 无终端模拟器/X 库/sudo（§1.2）；用 PTY grid+真实字体 PNG 替代 |
| clangd 真实 $/progress 实机 | BLOCKED | 本机 clangd 未发进度事件（能力协商/后台索引空闲）；契约测试覆盖 |
| showMessageRequest 实机 coroutine | BLOCKED | 默认处理器 coroutine.yield 无法同步 dofile；契约测试覆盖动作返回/取消 |
| Windows/macOS/musl/其他 Neovim 版本 | 未验证 | §7 |
| GitHub CI / 网络发布 | 未执行 | 不宣称 CI 通过 |

---

## 7. 尚未审查、尚未修复与未验证平台

### 7.1 上游源文问题（只报告，不私改）
- H3-05 lua.cnx:341 示例字典 `{'a': 42}` 与输入 `a=2` 矛盾（上游笔误）。
- H3-11 windows.cnx:1253 terminal「作业结束前不可读改」与 Nvim 实际行为相反（上游陈旧文本）。
- batch0 备注 6 条（if_perl $nvim 自指、"test of each line" 笔误等）。
- native §7.2：E5100/E5101/E5114/--server 上游键与运行时措辞漂移（manifest.runtime_audit 已记录）；是否追加运行时键由维护者决策。

### 7.2 项目级术语决策（未做批量替换，留待裁决）
- **yank**：抽取(58)/复制(175)/yank(70) 三译并存，同文档内混用；需逐上下文裁定，非安全批量替换。
- **unnamed register**：无名/未命名 register 并存。
- **Normal mode**：普通模式(129)/Normal 模式(88) 并存（正常模式 2 处已统一为普通模式）。
- **alternate file**：已统一为「替换文件」（editing/cmdline/index/options），首现保留 (alternate file) 注。
- 这些不影响语义正确性，属一致性优化；批量替换有打穿比较位/示例风险，故仅报告。

### 7.3 Help 未逐句全审范围（如实声明）
超大 API 参考按系统抽查，未抽到条目仅结构校验：vimfn(~320)、options(~260)、lua(108)、lsp(57)、api、vimeval、map、pattern、luaref、luvref、syntax 语言正文等。各批报告附 skipped tag 清单与抽查数。**不声称这些范围全量语义通过。**

### 7.4 未验证平台
Windows、macOS、musl、其他 Neovim 版本（nightly 仅实验预警）；GitHub 实际 CI、网络获取与发布均未执行。native 自动接线仅 Linux/glibc+LuaJIT 验证。

### 7.5 实机 BLOCKED 项
真实 GUI 终端截图、clangd 真实进度事件、showMessageRequest 实机 coroutine（§6）。契约测试与 PTY grid 覆盖相应逻辑，但不冒充"实机已通过"。

---

## 8. 资源构建、回归与发布检查结果

最终验证（当前工作树，`logs/final-round3.log`）：
```
SYNTAX=PASS py=30 sh=10 lua=101
CATALOG_CHECK=PASS domains=5 entries=410
NATIVE_CHECK=PASS exemptions=12 gaps=130 repairs=8 supplement=118 intro=6
REPRODUCIBLE_BUILD=PASS generated_lua native_mo complete_resources
UNIT_RESULT=PASS  CONTRACT_RESULT=PASS  TOOLS_RESULT=PASS
HELP_PARITY=PASS documents=133 problems=0
INTEGRATION_RESULT=PASS  E2E_RESULT=PASS
RELEASE_CHECK=PASS files=465
MAKE_EXIT=0  UP_EXIT=0（test-upstream）  NC_EXIT=0（native+clangd）
REAL_CLANGD_SMOKE=PASS push=6/6 pull=unsupported_method_not_found corpus=5/7 raw=unchanged
```
- 新增回归：`tests/contract/plugins/startup_late_attach_spec.lua`（BUG-01）、`tests/upstream/telescope_first_picker_spec.lua`（BUG-05）。
- 负向契约保留：查询无副作用、配置失败回滚、损坏资源保留旧集、实现冻结与重启提示、原生恢复失败重试、外部函数所有权、诊断/LSP/quickfix 原始数据、并发活动资源与最终磁盘代次、TUI 只读/窄终端/关闭清理。
- `git diff --check` 干净；生成 Help 继承空白与编辑源逐字节一致（parity 证明），未为消除 Git 空白提示破坏 Help 内容。
- 修改 PO/Help/native/运行实现后按生成流程重建相关生成物，未手改生成文件。

---

## 9. 证据归档位置

`nvim-zh-audit-evidence/`（仓库外，715 MB，含固定上游源码）：
- 审校报告：`reports/review-{which-key,telescope,tree-ui-clangd,native}.md`、`reports/help-review-batch{0..5}.md`
- 缺陷登记：`reports/confirmed-bugs.md`（BUG-01…05 完整证据链）
- 实机网格：`reports/live-matrix-grids.json`、`reports/layout-matrix-grids.json`、`renders/*/{*.json,*.raw,*.png}`
- Help 遍历：`reports/help-traverse.json`（133 篇）；超宽分类：`reports/help-wide-*.json`；fence 比对：`reports/fence-global-check.json`
- refine 边界：`reports/refine-boundary-evidence.json`
- 门禁日志：`logs/final-round3.log` 等
- 原件备份：`work/*.before-*`

发布包不含日志/缓存/研究源码/临时探针（release-check 465 文件验证）。