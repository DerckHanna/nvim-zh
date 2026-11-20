# 中文工作流

## C/C++ 编辑、构建和调试

1. 在项目目录打开 Neovim，在 `:NvimZhPacks` 安装 `clangd` 汉化包。使用自己的 clangd 配置与编译数据库。调试时先配置 nvim-dap 和 CodeLLDB，使用 nvim-dap-view 时可安装同名汉化包。检查 `:NvimZh` 的 C/C++ 状态。
2. 在含中文路径的项目中，用 `:edit 练习.cpp` 打开文件，或用 `:vimgrep /搜索标记/ *.cpp` 搜索，按 `:copen` 查看结果并按回车跳转。查阅 `:help nvim-zh-cpp`、`:help quickfix` 和 `:help lsp`。
3. 用 `vim.diagnostic.open_float({ scope = 'buffer' })` 查看中文诊断和错误码。下面的命令显示当前行的原文、位置和原始 LSP 对象。

   ```vim
   :lua vim.print(vim.diagnostic.get(0, { lnum = vim.fn.line('.') - 1 }))
   ```

   `code` 是错误码，`message` 是原文，`user_data.lsp` 是原始诊断对象。通过 `vim.lsp.buf.code_action()` 选择修复，核对改动后保存。使用 `K` 查阅悬浮说明，使用 `<C-s>` 请求签名帮助。
4. 配置项目的 `makeprg` 和编译器，例如 GCC 项目用 `:compiler gcc`。执行 `:make!` 收集结果，再用 `:copen`、`:cc` 和 `:cnext` 查看并跳转。Linux 上用 Bash 且 `shellpipe` 通过 `tee` 保存输出时，可用 `set shellcmdflag=-o\ pipefail\ -c` 保留构建进程的失败状态。用 `:echo v:shell_error` 查看退出状态，然后修复并重跑构建。
5. 在源文件用 `:DapToggleBreakpoint` 设置断点，`:DapContinue` 启动或继续，`:DapViewJump scopes` 查看变量。作用域标签可以汉化，变量名、值、断点行和退出状态由调试器决定。
6. 用 `:NvimZhPacks update clangd` 检查更新，`:NvimZhPacks rollback clangd` 回到历史版本。断网时可导入附件或回滚已有快照。工具包按 LSP 初始化返回的服务器身份和版本选择译文，并按协议方法启用显示面。版本、接口或词条缺失时查看原文和错误码。

## 测试失败、Git 冲突和 Python 检查

- **pytest。** 使用 `:compiler pytest` 和 `:make! test_算术.py`。在 quickfix 选中带文件和行号的条目，按回车跳到断言，修复后重跑。测试标识、断言表达式和命令输出按原样进入 quickfix。
- **Git 冲突。** 从 `git status --short` 找到 `UU` 文件。用 `:vimgrep /<<<<<<< HEAD/g %` 定位冲突，再用 `:copen` 或 `:cc` 跳转。编辑并保存后运行 `:!git add -- 说明.txt`，用 `git ls-files -u` 确认冲突项清除。需要左右对照时查阅 `:help diff`。
- **Ruff。** 使用 `:compiler ruff` 和 `:make! 检查.py`。例如按 `F401` 找到未使用的导入，跳转后确认无引用再移除，重新运行检查。

| 环节 | 中文与回退 |
| --- | --- |
| 搜索、编辑、跳转 | 核心 Help、常用 Lua UI 和提示使用中文。原有命令、文件路径和位置照常使用。 |
| clangd | 匹配的诊断、相关说明、修复、悬浮、重载补全、签名与索引提示可显示中文。缺包、暂停或版本未知时阅读上游说明。 |
| Make、pytest、Ruff | 中文 Help 指引，按工具自带的格式解析位置。编译、测试和检查输出保留原文及工具标识。 |
| CodeLLDB | 已验证的 nvim-dap-view 与 CodeLLDB 组合可汉化作用域和其他固定标签。用户输入、程序 stdout 与 DAP 值保持原样。 |
| Git | 中文 diff 和 quickfix Help。冲突标记、Git 命令及索引对象保留原样。 |
