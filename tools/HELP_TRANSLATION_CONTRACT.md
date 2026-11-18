# Help 翻译机械契约（nvim-zh）

本文件是 `doc/*.cnx` 译文执行的唯一权威契约。子代理任务书只写「阅读本文件」，
具体差异写在任务书里。校验由 `tools/help_parity.py` 在 pinned runtime 上
逐字节执行，并由 `manifests/help_inventory.json` 的 `contract` 摘要在**所有** Neovim
版本上强制（见下）。

## 绝对边界

1. 不是 Git 仓库。禁止 `init` / `commit` / `push` / PR / tag / 发布。
2. 只写任务书指定的**那一个** `doc/<name>.cnx`。不得创建、修改、删除仓库内任何其它文件。
3. 禁止在仓库内留下临时文件、草稿、探针脚本、HANDOFF、续跑文件。
4. 禁止改动系统 locale、Neovim 本体、第三方插件源文件。

## 本机环境陷阱

- `HOME`（/home/hanna）与 `/run/user/1000` **只读**。任何不带 `XDG_STATE_HOME` 的
  `nvim` 调用都会往**当前目录**写 `nvim.log`；任何不带 `PYTHONDONTWRITEBYTECODE=1`
  的 `python3` 可能写 `__pycache__`。两者都会让 `make release-check` 失败。
- 因此每条命令都必须带前缀：

      XDG_STATE_HOME=$(mktemp -d) PYTHONDONTWRITEBYTECODE=1

- `/tmp` 与 `/dev/shm` 每次工具调用都是**独立**的，跨调用不保留；`/var/tmp` 不可写。
  不要指望上一次写的中间文件还在。
- 看文件用 `read` 工具，找文件用 `glob`/`grep` 工具，不要用 `cat`/`find` 代替。
- 追加写入必须用带引号的 heredoc，防止 shell 展开 `$`、反引号、`\`：

      cat >> doc/<name>.cnx <<'NVZHEOF'
      ...内容...
      NVZHEOF

  单引号必须包住 `NVZHEOF`。绝不要用不带引号的 heredoc 或 `echo`。

## 结构保真（逐字节校验）

1. **help tag 集合**必须与上游完全一致：不丢失、不新增、不重复、不改变指向。
   tag 语法：`*` 前是行首/空格/Tab，闭合 `*` 后是行尾/空格/Tab/`*`。
2. **陷阱 A**：闭合 `*` 后若直接跟中文标点（`。`、`、`、`，`、`）`），该 tag 会被
   `:helptags` 静默丢弃。惯用写法是 tag 后留一个 ASCII 空格或 Tab：

       *some-tag*  中文说明。

3. **陷阱 B**：`:helptags` **不索引**示例块内部的 `*tag*`（`helphelp.txt`、
   `autocmd.txt`、`usr_41.txt` 都有块内 tag）。本项目扫描器与 `:helptags` 一致地跳过
   块内 tag。绝对不要为了「补齐 tag」把块内文本提升成独立 tag 行。
4. **示例块块体必须逐字节等于上游**：
   - fence 行匹配 `(^| )>[a-z0-9]*$`（即 `>` 在行首或紧跟一个 ASCII 空格，行尾）。
   - 块体 = fence 之后**所有**以空格/Tab 开头的连续行；fence 行本身不算块体。
   - 块内英文引文、空行、缩进（Tab 就是 Tab）、注释、对齐，一个字都不许改。
   - 用户手册里 `To err is human... ~` 这类是**被演示的文本**，保持英文是正确的，
     不算漏译。
5. **`|链接|`**：所有 `|...|`（含 `|06.1|`、`|gO|`、`|usr_40.txt|` 这类）出现次数与
   上游完全一致，不得增删改。
6. **不得省略、压缩或跳过任何段落**；难译处也要译；禁止「（略）」「（省略）」。
7. **保留原文**：命令、选项名（`'xxx'`）、变量、函数与 API 名、事件名、快捷键
   （`<...>`）、寄存器名、URI/URL、路径、占位符、代码标识符、highlight 组名、
   颜色名、错误号（`E325` 等）、数值。
8. **术语硬约束**（`translations/glossary/zh_CN.toml`，由
   `tests/contract/help/test_terminology.py` 强制）：Buffer / Window / Register 保留
   英文原词，译文正文**绝对不得出现**「缓冲区」「窗口」「寄存器」。
   - 沿用上游大小写：上游写 `window` 就写 `window`，`VIM::Buffer` 这类标识符原样保留。
9. **输出编码**：UTF-8 无 BOM、纯 LF、以换行结尾、权限 644。
10. **modeline 与文件头**：首行 `*<name>.txt*` 头与末行 `vim:tw=78:...` modeline
    逐字节照抄上游，不要凭记忆改写（不同文件 `et`/`noet` 不同），末行之后不得再多出
    空行。`contract.tail_digest`（`manifests/help_inventory.json`，由固定上游算出）
    会在**所有**版本断言「最后一个非空行到 EOF」与上游逐字节一致——实测曾有两篇违反：
    `lua-guide.cnx` 的 modeline 多一个前导空格、`starting.cnx` 在 modeline 后多一个空行。
11. **排版**：行宽约 78 列（东亚字符按 2 列计），段落空行与上游一一对应；
    `====` / `----` 分隔行保持位置。译文可以因中文重排而比上游行数少，但段落数必须一致。

### 陷阱 C：首行必须逐字节照抄上游（0.10/0.11 会毁掉整个 tags-cn）

Neovim 0.10/0.11 的 `:helptags`（`src/nvim/help.c`，`helptags_one()`）**只看每个文件的
首行**判定编码：首行含非 ASCII 字节算 utf-8，纯 ASCII 算 latin1；同一 `doc/` 里两种
混用时抛 `E670: Mix of help file encodings within a language`，**中止该语言并写出一
个空的 `tags-cn`**——进程仍以 0 退出，`make release-check` 也看不出来。所以首行绝不能
写中文，中文标题另起一行（与其余 133 篇一致）：

    *ft_ps1.txt*  A Windows PowerShell syntax plugin for Vim   <- 正确：上游首行

                                    适用于 Vim 的 Windows PowerShell 语法插件   <- 中文标题

`tests/integration/help/test_tags.py::test_first_lines_share_one_encoding_class` 与
`test_helptags_regeneration_is_not_destructive` 会在所有版本上拦住这类改动。

## 单文档自检门

复用项目现成引擎，**不要**另写第二套 parity 逻辑：

    cd /home/hanna/desktop/nvim-zh && XDG_STATE_HOME=$(mktemp -d) PYTHONDONTWRITEBYTECODE=1 python3 -c "
    import sys, os; sys.path.insert(0,'tools')
    import help_parity as c
    from pathlib import Path
    n='<NAME>'
    u=Path(os.environ['VIMRUNTIME']+'/doc/'+n+'.txt').read_text(encoding='utf-8')
    t=Path('doc/'+n+'.cnx').read_text(encoding='utf-8')
    st,tt=set(c.tags(u)),set(c.tags(t)); sb,tb=c.example_blocks(u),c.example_blocks(t)
    sl,tl=c.links(u),c.links(t)
    print('MISSING',sorted(st-tt),'EXTRA',sorted(tt-st),
          'DUP',[x for x in tt if c.tags(t).count(x)>1],
          'BLOCKS',len(sb),len(tb),'BAD',[i for i,(a,b) in enumerate(zip(sb,tb)) if a!=b][:20],
          'LINKDIFF',{k for k in set(sl)|set(tl) if sl.get(k,0)!=tl.get(k,0)},
          'FORBID',sum(t.count(w) for w in ('窗口','缓冲区','寄存器')),
          'FIRSTLINE_ASCII',all(b<0x80 for b in open('doc/'+n+'.cnx','rb').read().split(b'\n',1)[0]),
          'SELF',(n+'.txt') in tt)"

必须跑到：`MISSING [] EXTRA [] DUP [] BLOCKS n n BAD [] LINKDIFF {} FORBID 0
FIRSTLINE_ASCII True SELF True`。

收尾污染检查（必须为空）：

    find /home/hanna/desktop/nvim-zh \( -name nvim.log -o -name .nvimlog -o -name '__pycache__' -o -name '*.pyc' \) -print

## 返回格式

    DOC: <name>
    SRC_SHA256 / OUT_SHA256 / LINES / TAGS / EXAMPLE_BLOCKS / LINKS
    GATE: <自检门原样输出>
    FORBIDDEN: 0
    FILES_CHANGED: doc/<name>.cnx
    SELF_CHECK_PASSED: yes/no

未跑成功检门就返回等于任务失败。做不到要如实说明，绝不谎报。

## 超大文档

如果任务书**没有**明确写「本篇采用分段接力」，那么本篇必须由你**一次写完整篇**，
不使用任何占位符，块体直接从上游原文照抄。占位符流程只属于任务书里指定行区间的
接力代理，见 tools/HELP_RELAY_PROTOCOL.md；本篇契约一律按整篇翻译执行。
