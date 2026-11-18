# 兼容性与验证边界

## 支持范围

| 项目 | 支持口径 |
|---|---|
| Neovim | 0.12+；完整翻译和 Help 基线固定为 0.12.6 |
| 安装/更新 | 内置 `vim.pack`；其他管理器不作为本项目的正式安装/更新路径 |
| 自动原生 gettext | Linux/glibc + LuaJIT；必须通过真实 MO 哨兵查询才算生效 |
| 中文 Help / Lua UI | 不依赖原生 FFI 能力；原生部分失败时独立降级 |
| nightly | CI 中仅作实验性预警，不形成稳定兼容承诺 |
| Windows、macOS、musl、无 FFI 构建 | 原生自动接线未承诺支持；不能据 Linux 结果外推 |

项目不再维护 0.10/0.11 的独立基础入口，也不保留旧命令、旧 Lua API 或旧测试目录的兼容层。旧版本的历史测试记录不能作为当前版本通过证据。

## 机器清单代表什么

### 中文 Help

`manifests/help_inventory.json` 当前记录固定 0.12.6 runtime 的 135 篇文档：133 篇在编辑 manifest 中标为 `complete`，2 篇有证据地排除（`credits.txt`、`uganda.txt`）。项目自有 `nvim-zh.txt/.cnx` 不计入这 133 篇。

`complete` 表示维护者声明的翻译状态，并有 tag、示例块、链接、索引和固定上游摘要等结构契约。它不等于逐句语义审校，也不等于“全部 Neovim 已汉化”。运行时缺少中文 tag 时自然回退英文。

### 核心 gettext

固定上游目录有 1 985 条消息，其中 1 855 条上游已译、130 条上游空缺。本项目编辑源补充 118 条，另外 12 条由上游明确标注不翻译。

补充 118 条**不等于 118 条都已验证生效**。`manifests/native.json` 的固定二进制/runtime 审计记录：76 条只匹配裸键、25 条同时需要带错误码前缀的运行时键、2 条来自 runtime 文件、15 条未在固定二进制和 runtime 树中确认。未确认的 15 条继续如实标为未验证，其中 4 条已识别为上游 PO 措辞与运行时字面量漂移。

合并 MO 使用 Neovim 原生 gettext 机制，从用户数据目录的已验证快照读取，不替换系统 MO。

## 第三方插件

| 插件 | 固定 commit | 已验证接缝边界 |
|---|---|---|
| which-key | `3aab2147e74890957785941f0c1ad87d0a44c15a` | preset desc、生成数量、精确 title 通知；footer 与私有 Buffer 不覆盖 |
| Telescope | `40aedd8a68c78a656a10a8d62d80c54af59420fb` | 初始标题显示投影、静态/动态 previewer 标题、通知；内部英文行为值和最终 refine 标题不覆盖 |
| nvim-tree | `69eb0c34ed3d836d5a0d92d913b77dd73b054f2f` | 默认 on_attach 映射后缀与通知；用户自定义描述、已有 Buffer 和私有 renderer 不覆盖 |
| nvim-dap | `cfa2d58f4537aca6ca83e2de1a0d9f1491121264` | 精确 title 通知、结构化选择器、REPL 帮助、直接输入提示、quickfix 显示副本与健康报告；协议、日志、调试器输出和已有 REPL 不覆盖 |
| nvim-dap-ui | `cc9dd33aade7f20bae414d0cba163bc60d4d4b43` | 高亮限定的固定 render 文本、mapping 描述、浮窗标题、选择器、默认 Window 提示与通知；动态 DAP 数据和已有 Buffer 不改写 |
| lazy.nvim | `306a05526ada86a7b30af95c5cc81ffba93fef97` | `User LazyLoad`；主面板私有 view 不覆盖 |
| nvim-cmp | `2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3` | inventory-only，没有可证明安全的 cmp 自有固定标签 |

这些固定版本和实际检查的源码 SHA-256 见 `manifests/upstreams.json`。相同 API 形状的其他版本可能工作，但不自动获得“已验证”结论。详细限制见[第三方插件适配](adapters.md)。

## 诊断、LSP 与外部工具

诊断/LSP 适配仅处理明确识别的 clang/clangd 显示文本。固定 fixture 和真实服务器观察用于发现回归，不是整个 clangd 的覆盖率。原始诊断、quickfix、LSP 协议对象、日志和外部工具 stdout/stderr 不修改。

真实 clangd pull 的支持取决于服务器能力；不支持的方法要报告真实错误，不能把它写成成功。测试必须同时保留成功 pull 反例，避免用 `and/or` 之类表达式让已知消息断言失效。

## 验证与 SKIP 规则

- 默认 `make test` 是离线套件，包含真实本地 PTY 和临时 Git 仓库的 vim.pack 集成，不要求第三方源码或网络。
- `make test-upstream` 要求固定第三方源码目录真实存在；缺环境是未完成/失败，不得以 SKIP 退出成功。
- 真实 native/clangd 检查有独立显式入口。只有平台或版本确实不适用时才允许 SKIP；版本探测失败、空输出、超时和工具错误不得降级为 SKIP。
- CI 配置存在不等于 CI 已在本机或 GitHub 实际通过。没有实际执行的平台、版本或网络检查不列为 PASS。
- 当次重构的命令、结果和剩余限制记录在[验证报告](verification.md)；历史记录不作为当前通过凭证。
