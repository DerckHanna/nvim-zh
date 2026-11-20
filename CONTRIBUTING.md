# 贡献指南

## 先分清编辑源与生成物

| 内容 | 编辑源 | 生成物 | 常用检查 |
|---|---|---|---|
| UI/插件目录 | `translations/po/zh_CN/*.po`、`translations/glossary/zh_CN.toml` | `lua/nvim-zh/catalogs/generated/`、`resources/catalogs/` | `make check-translations check-reproducible` |
| 核心 gettext 消息 | `translations/native/*.po`、`manifests/native.json` | `build/native/`、资源中的 MO | `make check-native` |
| 上游 Neovim Help 译文 | `doc/*.cnx`、`manifests/upstreams.json` | `doc/tags*`、`manifests/help_inventory.json`、资源 Help | Help contract/integration suites |
| 项目自有 Help | `doc/nvim-zh.txt`、`doc/nvim-zh.cnx` | 项目 tag 与资源 Help | `:help nvim-zh` 与 Help suites |
| 第三方适配与 Help | `manifests/adapters/`、`translations/adapters/`、PO、`translations/help/adapters/` | `manifests/adapter-index.lua`、独立汉化包 JSON 附件 | `make check-adapters test-upstream` |
| 运行时实现 | `plugin/`、`lua/nvim-zh/` 中非生成 Lua | 资源清单中的实现标识 | `make check-syntax test-contract test-integration` |
| 完整交付资源 | 上述所有输入 | `resources/` | `make build-resources check-resources` |

生成文件不手工编辑。`build/` 是维护端缓存和中间产物；`resources/` 是随包交付的确定性资源集。安装端不运行 Python、`msgfmt`、`:helptags` 或构建 hook。

## 本地检查

要求 Neovim 0.12+、Python 3 和 GNU Make。核心 MO 重建还需要 gettext 的 `msgfmt`；固定上游 PO 已缓存时，常规构建离线完成。

```bash
make check-syntax        # Lua loadfile、Python AST、Shell bash -n
make check-translations # PO、占位符、重复键、UTF-8、术语与代码保护
make check-native       # 核心消息、豁免、修复清单和术语
make build-resources    # 重建 Lua 目录、MO 和完整 resources/
make check-resources    # 检查陈旧、缺失和多余资源
make check-reproducible # Lua、MO 与完整资源逐字节可重复
make test               # 默认离线测试与真实本地 TUI/vim.pack；发布检查另行执行
```

测试分类、可选真实 native/clangd 入口和固定第三方源码要求见[测试文档](docs/testing.md)。不要把未执行、SKIP 或环境受阻记为 PASS。

## 运行时结构

公共 Lua 入口只位于 `lua/nvim-zh/init.lua`。内部职责：

- `session`：有效配置和模块应用/恢复；
- `runtime`：配置、资源和包事件的唯一同步协调器；
- `resources` / `native_backend`：不可变资源快照与原生进程状态；
- `catalog` / `engine` / `missing`：精确翻译、模板和本地观察；
- `ui` / `diagnostics` / `lsp`：Neovim 公共显示接缝；
- `plugins` / `adapters`：薄管理器与每插件独立适配；
- `status` / `health`：只读快照和检查。
- `packs` / `pack_store` / `tui`：包操作、快照与安装登记、状态展示和面板交互。

查询不得隐式 setup、下载、更新或写资源；渲染层不承载同步流程。不要通过 `require('nvim-zh')` 从底层模块回到公共入口形成循环。完整说明见[架构文档](docs/architecture.md)。

## 修改第三方适配

单插件清单、Lua、PO 和场景用例应成组维护。先阅读[适配系统设计](docs/adapter-system-design.md)。

1. 在 `manifests/adapters/<id>.json` 固定插件、依赖、Neovim 和实际审查的源码摘要。优先使用有来源证据的正式显示接口。
2. 为每个新增或修改的显示面补充离线契约与真实 TUI 场景，保留用户数据、按键与回调语义。
3. 运行 `make build-resources` 与 `python3 tools/adapter_tool.py check <id>`。上游测试入口会重跑该适配器的完整 TUI 场景，取源与执行方式见[测试文档](docs/testing.md)。
4. 更新上游时，使用 `discover`、`fetch` 和 `audit` 生成候选证据。候选通过后更新正式清单与发布资源。发布报告记录实际验证的组合及场景。

## 修改 PO 与术语

译文写法、词条选取和审校口径见[简体中文翻译规范](docs/translation-style.md)。

```bash
make check-translations
make build
make check-reproducible
```

- 每个插件/服务器使用独立 domain，每个语义场景使用稳定 `msgctxt`。
- 保留真实 `#:` source reference，不从测试 fixture 编造产品文本。
- 动态文本使用审查过的 `{name}` 或 printf 占位符。保留命名参数的名称和次数，以及 printf 参数的顺序和类型。
- 命令、选项、代码、路径、URI、快捷键和反引号内容必须保留。
- 空译文、fuzzy、占位符不匹配、重复键和受保护文本变化均应失败。
- `translations/glossary/zh_CN.toml` 是术语检查真源；运行时不做最终文本全局替换。

Buffer、Window、Register 当前采用 `preserve`：这些名称同时承担 Neovim 对象/API 含义，保留英文可避免把技术对象与普通中文窗口、缓冲区或寄存器混淆。该策略只用于精确编辑源检查，不授权运行时改写用户文本。改变策略时必须同步 PO、Help 契约和文档，而不是只改一个 TOML 文件。

## 上游 Neovim Help 译文

1. 从 `manifests/upstreams.json` 固定的 commit 获取英文原文，记录源路径和 SHA-256。
2. 新建或修改对应 `doc/<name>.cnx`，保留英文 help tag、`|链接|`、示例块、默认值和警告。部分翻译标为 `partial`，不得计为 `complete`。
3. 遵守 glossary 和 Help tag 的空白规则：闭合 `*` 后直接跟中文标点会让 tag 被忽略，惯用写法是 `*'tag'*  中文说明。`
4. 用固定 Neovim 重新生成索引，不手写：

   ```bash
   nvim --headless -u NONE -i NONE -n -c 'helptags doc' -c 'qa!'
   ```

5. 运行 Help contract/integration 检查；文档集合变化时重新生成 `manifests/help_inventory.json`：

   ```bash
   python3 tools/help_inventory.py
   ```

唯一 parity 引擎是 `tools/help_parity.py`，`help_relay.py` 与 `help_inventory.py` 都调用它。不要在测试或维护工具里复制第二套 tag/block/link 逻辑。

长文档分段操作见 `tools/HELP_RELAY_PROTOCOL.md`，保真要求见 `tools/HELP_TRANSLATION_CONTRACT.md`。relay 只接受 manifest 登记的精确 basename 和固定 hash；`assemble` 必须在全部契约通过后原子替换，失败保留原 bytes/mode。

### 项目自有 Help 不是上游译文

`doc/nvim-zh.txt` 与 `doc/nvim-zh.cnx` 描述本插件的命令、配置、API 和限制。它们不计入上游 Neovim Help 的 `complete` 数量，也没有上游 Neovim commit/parity 关系。

修改公共接口时同步这两个文件并重建 tag/资源。**不要为了整理项目叙述批量改写其他上游 `.cnx`。**

## 核心 gettext 消息

1. 用 `python3 tools/native_catalog.py stats` 检查固定上游缺口；只编辑 `translations/native/` 中对应 PO。
2. 上游标为 `# do not translate` 的条目保持豁免，并在 `manifests/native.json` 记录证据。
3. printf/宏占位符、`E###`/`W###` 和尾随空格逐字保留。
4. 上游 msgid 与运行时键不一致时，必须凭固定源码/二进制证据使用 repairs、prefix_repairs 或 intro 清单，不猜键。
5. 执行：

   ```bash
   make check-native
   make build-native       # 缓存存在且 hash 匹配时离线
   make audit-native       # 可选：核对本机固定 nvim 二进制与 runtime
   make build-resources
   ```

`make sync-native` 是显式联网获取固定上游 PO 的入口。找不到运行时字面量的补充条目不得宣称已经生效。

## 上游同步

```bash
make sync        # 默认离线只读
make sync-fetch  # 显式联网：共享上游清单的固定源码
make sync-native # 显式联网：Neovim 核心 PO
```

第三方适配器使用 `tools/adapter_tool.py` 独立发现与校验候选。同步报告中的 `UPSTREAM_CHANGE`、`STALE_TRANSLATION`、`UNTRANSLATED` 需要逐条审查。

## 发布

生成独立汉化包附件和目录索引时，请将输出放在主包工作树之外。

```bash
python3 -B tools/pack_assets.py --id telescope --version 1.0.0 --output /tmp/nvim-zh-packs
```

省略 `--id` 会为所有支持的目标分别生成附件。发布单包新版本时，用
`--index /path/to/catalog.json` 合入现有目录，维护其他包和历史版本。先发布并核验
`packs-<id>-v<版本>` 对应附件，再更新同仓库 `packs` 分支的 `catalog.json`。
开发验证可用 `:NvimZhPacks! import` 在本地导入含 Lua 的附件。

相关实现、PO、Help 或 native 输入变化后，重建并检查完整资源，运行默认测试和 `make release-check`。固定上游 smoke 使用 `make test-upstream`，所需固定源码目录必须真实存在。

发布检查从当前工作树复制临时候选包，过滤 `.git` 与空的工作环境挂载目录，再校验剩余文件。日志、缓存、零字节临时件和研究下载均会阻止发布。

提交、推送、打 tag 和发布由维护者明确授权。验证使用独立测试目录。见[发布清单](RELEASE_CHECKLIST.md)。
