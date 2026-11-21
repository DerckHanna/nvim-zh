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

## 运行时改动

公共 Lua 入口位于 `lua/nvim-zh/init.lua`。同步由 `runtime` 协调，`pack_store` 负责附件和快照验证。查询和渲染保持只读。新增显示接缝时，应核对来源、保存上游回调的数据和返回值，并为停用及外部覆盖补充测试。详见[架构](docs/architecture.md)。

## 修改第三方适配

单插件清单、Lua、PO 和场景用例应成组维护。先阅读[适配系统设计](docs/adapter-system-design.md)。

1. 在 `manifests/adapters/<id>.json` 固定插件、依赖、Neovim 和实际审查的源码摘要。优先使用有来源证据的正式显示接口。
2. 为每个新增或修改的显示面补充离线契约与真实 TUI 场景，保留用户数据、按键与回调语义。
3. 运行 `make build-resources` 与 `python3 tools/adapter_tool.py check <id>`。上游测试入口会重跑该适配器的完整 TUI 场景，取源与执行方式见[测试文档](docs/testing.md)。
4. 更新上游时，使用 `discover`、`fetch` 和 `audit` 生成候选证据。候选通过后更新正式清单与发布资源。发布报告记录实际验证的组合及场景。

## 修改译文

- 在对应 domain 的 PO 内记录真实源码引用和稳定 context。保留占位符、代码、命令、配置项、路径、URI 及快捷键。术语以 `translations/glossary/zh_CN.toml` 为准，见[翻译规范](docs/translation-style.md)。
- 更新 Help 时保留英文 tag、链接、示例块、默认值和警告。用固定 Neovim 执行 `helptags`，文件集合变化时运行 `python3 tools/help_inventory.py`。局部覆盖在清单中标为 `partial`。
- 工具链词条从 `translations/toolchain/zh_CN.json` 与固定 LLVM 来源生成。生成、审计和真实工具对照见[工具链覆盖](docs/toolchain-coverage.md)。

## 提交和发布

提交说明应概括用户可见的行为。合并请求说明复现步骤、验证命令和实际结果。生成物与对应编辑源放在同一改动中。发布过程见[发布检查清单](RELEASE_CHECKLIST.md)。
