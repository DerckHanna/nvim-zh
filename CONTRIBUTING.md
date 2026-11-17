# 翻译贡献指南

## 编辑源与构建

UI/插件静态目录的编辑源是 `translations/po/zh_CN/*.po`，术语规则在
`translations/glossary/zh_CN.toml`；Help 与核心消息各有下文所列的编辑源。
不要手改 `lua/nvim-zh/catalogs/generated/*.lua`。每个插件、服务器使用独立 domain，每个语义
场景使用稳定 `msgctxt`。保留 `#:` source reference，动态文本必须使用已审查的
`{name}` 或 printf 占位符，不把标识符、路径、类型或数字写死进译文。

```bash
make check-translations
make build
make check-reproducible
```

构建稳定排序、不写时间戳。命令、选项、代码、路径、URI 与反引号内容必须原样保留；
Buffer、Window、Register 等术语遵守 glossary。空译文、fuzzy、占位符不匹配和受保护
文本变化都会被拒绝。

## 新增 Help 文档译文

1. 从 manifest 固定的 commit 取英文原文，并记录源文件路径与 SHA-256。
2. 新建 `doc/<name>.cnx`，完整保留英文 help tag、`|链接|`、示例块、默认值与警告。
   术语按 `translations/glossary/zh_CN.toml` 执行，该 glossary 对 Help 正文同样有效：
   `preserve` 词条只能保留英文写法，禁用形式（`窗口`/`缓冲区`/`寄存器`）一律不得出现。
   **tag 识别要求 `*` 前后都是 ASCII 空格/Tab/行首/行尾**：闭合 `*` 后面直接跟中文
   标点（`。`、`，`、`）`）会让该 tag 被静默丢弃。惯用写法是
   `*'tag'*  中文说明。`（tag 后保留一个空格）。`make test-phase8` 的 tag 双向检查
   会抓到这类丢失，但改起来很费时，落笔时就守住。
3. 在 `manifests/upstreams.json` 的 `upstreams.neovim.documents` 增加条目：`source`、
   `translation`、`status`（`complete` 或 `partial`）、`sha256`，以及说明覆盖范围的
   `notes`。部分翻译必须标为 `partial`，不得声称完整。
4. 用 Neovim 重新生成 tags，不要手写：

   ```bash
   nvim --headless -u NONE -c 'helptags doc' -c 'qa!'
   ```

5. 运行 `make test-phase8`，确认 tag 双向一致、示例块与链接未变、术语合规、`doc/tags`
   与 `doc/tags-cn` 与 `:helptags` 输出一致、`:help` 打开中文且英文回退正常。新增或
   删除文档后还要重新生成 `manifests/help_inventory.json`
   （`python3 tools/help_inventory.py`）。

长文档需要分段翻译时，`tools/help_relay.py` 的具体操作和限制见
`tools/HELP_RELAY_PROTOCOL.md`；译文保真要求见 `tools/HELP_TRANSLATION_CONTRACT.md`。
这两份文件描述 Help 翻译作业流程，不是插件运行时入口。

## 核心消息补充译文

1. 固定上游后运行 `python3 tools/native_catalog.py stats`，确认缺口条数；只编辑
   `translations/native/zh_CN.po`，msgid **逐字**照抄固定上游目录（含 `%<PRId64>` 这类
   宏占位符和尾随空格），只写 `msgstr`。
2. 上游自己标注 `# do not translate` 的条目不得翻译：保持英文，并在
   `manifests/native.json` 的 `exemptions` 记录 msgid、marker、refs 与理由。
3. 占位符序列（`%s`、`%.*s`、`%<PRIu64>`、`%` 字面量）必须与 msgid 完全一致，`E###`/`W###`
   错误码保留在译文开头，术语按 glossary（`窗口`/`缓冲区`/`寄存器` 不得出现）。
4. 上游 Msgid 与运行时键不一致时按证据修复，不猜：
   - 抽取截断（如 `E5403: Chunk %i start %`）写入 `translations/native/runtime_repairs.po`，
     并在 manifest 记录上游源码行证据；
   - 运行时另有一条带 `E###: ` 前缀的调用点时，在 manifest 的 `prefix_repairs` 记录前缀与
     二进制证据，构建时自动补同前缀条目。
5. 改动后跑 `make check-native`、`make build-native`；换 Neovim 版本还要跑
   `make audit-native` 复核 `runtime_audit`（二进制相关，必须重测）。
6. 产物只写 `build/`。不安装 MO、不改系统 locale、不动 Neovim 本体和发行版目录；
   找不到运行时字面量的条目不得声称已生效。

```bash
make check-native
make sync-native    # 仅在首次或换版本时联网
make build-native
make audit-native   # 可选，需本机 nvim 二进制
```

## 新增适配器

1. 先固定上游完整 commit 和实际检查的 SHA-256，并引用公开 API 文档/源码。
2. 先写会失败的差分契约测试，再实现；baseline 与 translated 只允许显示字符串不同。
3. 适配器只调用 `nvim-zh.engine`，不得新增模糊匹配或第二套模板引擎。
4. 必须有独立开关、setup/teardown/reload、外部替换检测、Info/health 状态。
5. 未命中、未知版本、异常、无私有所有权证明时保留原文。不得修改协议对象、原始
   mapping/item/diagnostic、quickfix 输入、终端字节流或第三方源文件。
6. 真实上游 smoke 与离线测试分离；不把固定 fixture 覆盖率宣传为整个插件/服务器覆盖率。

## 同步上游

`make sync` 默认不联网。离线已有源码可运行：

```bash
python3 tools/catalog_tool.py sync --source-root /path/to/named-checkouts
```

只有显式入口 `make sync-fetch`（等价于 `python3 tools/catalog_tool.py sync --fetch`）才
读取 manifest 中固定 commit 的 GitHub raw 内容；`--fetch` 是工具参数，不是 make 参数，
所以 `make sync --fetch` 会被 make 当成未知选项而失败。它不会写上游、
更新译文或上传数据。报告区分 `UPSTREAM_CHANGE`、`STALE_TRANSLATION` 与
`UNTRANSLATED`，按报告逐条审查后再人工修改 PO/manifest。

## 检查与产物

| 改动 | 编辑源 | 生成物 | 最小检查 |
|---|---|---|---|
| UI/插件文字 | `translations/po/zh_CN/*.po`、glossary | `lua/nvim-zh/catalogs/generated/*.lua` | `make check-translations check-reproducible test-phase2` |
| Help 译文 | `doc/*.cnx`、`manifests/upstreams.json` | `doc/tags`、`doc/tags-cn`、`manifests/help_inventory.json` | `make test-phase8` |
| 核心消息 | `translations/native/*.po`、`manifests/native.json` | `build/native/` 下的合并 PO、MO、审计报告 | `make check-native test-phase9` |
| 运行时代码 | `plugin/`、`lua/nvim-zh/` 中非 generated 的 Lua | 无 | 相关阶段的 `make test-phaseN` |
| 构建和维护工具 | `Makefile`、`tools/`、`tests/` | 按命令决定 | `make test-phase6` 及相关阶段 |

`tools/help_relay.py` 只接受 `manifests/upstreams.json` 中登记的精确文档基名，并强制
校验固定 sha256；`assemble` 在完整契约（tag/链接多重集/示例块/术语/自身文件 tag）
全部通过后才原子替换目标文件，失败时原字节与权限不变。阶段 6 的
`tests/phase6/test_help_relay.py` 与 `test_catalog_safety.py` 用合成输入覆盖这些失败路径。
构建/下载/审计报告统一先写临时文件再原子发布；`catalog_tool.py build` 只清理首行带
生成标记的过期 Lua，拒绝覆盖同名非生成文件或符号链接。

`build/upstream/zh_CN.UTF-8.po` 是固定上游目录的缓存，只有显式 `make sync-native`
才联网更新；`make build-native` 在缓存存在且 hash 匹配时离线构建。
完整离线回归用 `make test`；发布前再运行 `make release-check`，并按
`RELEASE_CHECKLIST.md` 人工核对。该目标从当前工作树复制临时候选包，排除
工作树自己的 `.git`，再检查候选包；若实际发布包含 `.git`，
`tools/catalog_tool.py release-check --package-dir <发布包目录>` 仍会拒绝。
阶段 0 的机制实验现位于 `tests/phase0/`，
入口为 `make test-phase0`。
