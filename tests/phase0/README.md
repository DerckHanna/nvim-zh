# nvim-zh 阶段 0：可重复研究实验

这些文件是研究/契约测试，不是插件运行时代码，也不修改用户配置、系统 locale 或第三方插件。

运行：

```bash
# 在仓库根目录执行
./tests/phase0/run.sh
```

可用 `NVIM_BIN=/path/to/nvim` 指定其他版本。研究环境需要 Neovim 与 gettext 的 `msgunfmt`；`localedef` 和系统 locale source 仅用于可选的 E1 正向控制。测试统一在 `${TMPDIR:-/tmp}/dsh-nvim-zh-phase0-<时间戳>` 下创建数据，退出时删除；项目目录不生成测试残桩或日志。正式审计证据写入阶段报告，不在工作区散落临时日志。

| 实验 | 验证内容 |
|---|---|
| E1 | 环境/LC_*、MO、直接 locale 尝试；用临时 `LOCPATH` 做中文正向控制 |
| E2 | `.cnx` → `tags-cn` → 中文帮助，以及英文最终回退 |
| E3 | notify 参数/返回、notify_once 原文去重、异步 select identity、input、echo 高亮/id |
| E4 | `vim.ui_attach` 只观察、不吞消息；历史/cmdheight 保持；记录微基准，不设跨机器阈值 |
| E5 | virtual text/lines/float 显示中文，存储诊断、LSP 元数据和未知文本回退不变 |

E4 性能数字只表示当前 headless 环境的事件开销，不是交互式 UI 性能结论。E3 的 echo 实验只证明技术契约，不代表默认启用 echo 包装。
