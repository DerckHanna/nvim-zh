# 贡献指南

## 先分清编辑源与生成物

| 内容 | 编辑源 | 生成物 | 常用检查 |
|---|---|---|---|
| UI/插件目录 | `translations/po/zh_CN/*.po`、`translations/glossary/zh_CN.toml` | `lua/nvim-zh/catalogs/generated/`、`resources/catalogs/` | `make check-translations check-reproducible` |
| 核心 gettext 消息 | `translations/native/*.po`、`manifests/native.json` | `build/native/`、资源中的 MO | `make check-native` |
| 上游 Neovim Help 译文 | `doc/*.cnx`、`manifests/upstreams.json` | `doc/tags*`、`manifests/help_inventory.json`、资源 Help | Help contract/integration suites |
| 项目自有 Help | `doc/nvim-zh.txt`、`doc/nvim-zh.cnx` | 项目 tag 与资源 Help | `:help nvim-zh` 与 Help suites |
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
- `status` / `health` / `tui`：只读快照、检查和展示。

查询不得隐式 setup、下载、更新或写资源；渲染层不承载同步流程。不要通过 `require('nvim-zh')` 从底层模块回到公共入口形成循环。完整说明见[架构文档](docs/architecture.md)。

## 修改第三方适配

先阅读[第三方插件适配](docs/adapters.md)和对应固定上游源码。每个适配器只修改自己名下的模块、PO 和测试；共享生命周期、通知来源注册和所有权机制集中在管理器/common 中。

新增或修改接缝时必须：

1. 固定完整 commit，并在 `manifests/upstreams.json` 登记实际检查文件及 SHA-256。
2. 优先使用稳定公开接口。版本相关实现要写明源码依据、支持范围和真实契约，不能仅凭 fixture 形状推断。
3. 保留原始条目身份、回调参数/返回值、快捷键、代码、路径和用户数据。显示副本与内部行为值分开。
4. 覆盖默认流程、重复 setup、晚加载、配置变化、模块换代、外部替换和 teardown。
5. 未知文本、未知版本或没有可靠接缝时自然回退，并在状态中说明。禁止全局模糊替换、任意 Buffer 扫描和改写第三方源文件。
6. 真实上游测试与离线测试分离；fixture 命中率不得作为整个插件的汉化率。

通知通过精确 `vim.notify` title 注册 domain，避免同一消息在插件与公共 UI 中被翻译或记录两次。没有可靠 title/来源的 prompt 不做归属猜测。

## 修改 PO 与术语

```bash
make check-translations
make build
make check-reproducible
```

- 每个插件/服务器使用独立 domain，每个语义场景使用稳定 `msgctxt`。
- 保留真实 `#:` source reference，不从测试 fixture 编造产品文本。
- 动态文本使用审查过的 `{name}` 或 printf 占位符，保持参数顺序和类型。
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
make sync-fetch  # 显式联网：UI/插件固定 commit 内容
make sync-native # 显式联网：Neovim 核心 PO
```

`--fetch` 是工具参数，所以 `make sync --fetch` 不是合法调用。同步不会写上游、更新译文或上传数据；`UPSTREAM_CHANGE`、`STALE_TRANSLATION`、`UNTRANSLATED` 必须逐条人工审查。

## 发布

相关实现、PO、Help 或 native 输入变化后，重建并检查完整资源，运行默认测试和 `make release-check`。固定上游 smoke 使用 `make test-upstream`，所需固定源码目录必须真实存在。

发布检查从当前工作树复制临时候选包，排除工作树自己的 `.git`，再拒绝日志、缓存、零字节临时件和研究下载。不得通过删除断言或扩大忽略范围绕过。

发布、打 tag、提交和推送都是维护者的人工决定；自动化不得自行执行，也不得把开发目录同步到用户已安装的插件目录。清单见 `RELEASE_CHECKLIST.md`。
