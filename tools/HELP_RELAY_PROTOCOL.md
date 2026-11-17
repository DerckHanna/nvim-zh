# 超大 help 文档：分段接力协议（nvim-zh）

只适用于任务书明确写了「本篇采用分段接力」的文档。其余文档一律按
`HELP_TRANSLATION_CONTRACT.md` 整篇翻译，**不要**使用占位符。

## 为什么需要接力

`runtime/doc/vimfn.txt` 有 12 491 行，任何单一代理的上下文都装不下「读完整篇 +
写出译文 + 逐字节比对」。而项目规则要求一篇文档只有一个写入代理，所以接力是
**串行**的：同一篇每次只有一个代理在写，它只负责自己那段行区间，追加到自己的
`doc/<name>.cnx`；主代理校验通过后才派下一个代理。

## 关键机制：示例块占位符

代理**不复制**示例块块体。它只写：

1. fence 行（`>` 之前那部分散文可以翻译成中文，但行尾必须保持
   ` >`、` >lua`、` >vim` 这种形式，使该行仍匹配 `(^| )>[a-z0-9]*$`）；
2. 紧接着一行，内容正好是 `@@BLOCK@@`（顶格、无缩进、无其它字符）。

块体由主代理用 `tools/help_relay.py assemble` 从上游原文按顺序注入。这样：

- 宽 ASCII 表、代码块永远不会被手抄破坏；
- **tag 与 `|链接|` 只存在于块体之外**，所以骨架（skeleton）的 tag 集合与链接
  计数就等于最终译文的——因此每段可以在注入之前被精确校验。

早期验证曾对 68 篇已验收译文做「骨架化 → 注入」往返，结果与原文
**逐字节相同**（含 `motion.txt` 的 19 块、`usr_41.txt` 的 146 块）。

## 代理每次要做的事

任务书会给出唯一的行区间 `FROM-TO`（1 基，含端点）、该段的示例块数、tag 数、
链接数。要求：

1. 用 read 工具读上游 `$VIMRUNTIME/doc/<name>.txt`（必须是 manifest 固定的
   0.12.6 runtime；`tools/help_relay.py` 会按 manifest sha256 校验，用错版本会直接拒绝），
   用 `offset=FROM limit=TO-FROM+1` 只读自己这段（可分几次读完，必须读全）。
2. 若文件不存在（首段）：用 write 创建；否则用带引号 heredoc 追加：

       cat >> doc/<name>.cnx <<'NVZHEOF'
       ...本段译文...
       NVZHEOF

   **绝对不许改动或删除已有内容**，也不许重复写别人写过的区间。
3. 只翻译本段。不要为「补齐 tag」提前写出后面区间的 tag 定义行。
4. 首段必须包含上游首行的 `*<name>.txt*` 文件头 tag；最后一段必须包含末行
   modeline（逐字节照抄）。
5. 追加后跑主代理给的 `tools/help_relay.py verify` 命令，报告里必须出现
   `RELAY_VERIFY=PARTIAL` 或 `RELAY_VERIFY=READY`（本段无误），且
   `RELAY_PROBLEM=` 行为空。看到 FAIL 就修正本段后重跑，直到干净。

## 禁止事项

- 禁止自己把 `@@BLOCK@@` 换成真实块体（注入是主代理的事）。
- 禁止 `> ` 结尾的散文被无意造出 fence 行：fence 行数必须等于占位符数，
  否则 verify 会 FAIL。
- 禁止缩进的 `@@BLOCK@@`（必须顶格）。
- 禁止写「（略）」「以下省略」，禁止跳过本段任何段落。
- 禁止创建任何临时文件进仓库；每条 nvim/python 命令都要带
  `XDG_STATE_HOME=$(mktemp -d) PYTHONDONTWRITEBYTECODE=1` 前缀。

## 主代理侧

    python3 tools/help_relay.py plan     <name.txt> --lines 300   # 生成区间表
    python3 tools/help_relay.py verify   <name.txt>              # 每段之后
    python3 tools/help_relay.py assemble <name.txt>              # READY 后注入
    # 注入后仍必须跑整篇真实门（check_help_parity 全文比对）才登记 manifest

`verify` 状态含义：`PARTIAL` 还有区间没写；`READY` 全部写完待注入；
`COMPLETE` 已注入且 tag 集合、`|链接|` 多重集、示例块与术语都与上游一致；
`FAIL` 本段有问题必须返工。`READY`/`COMPLETE` 都要求链接**多重集**相等，
只比总数不算通过。

`plan` 在 ±150 行窗口内找不到安全切点时，仍保留「剩余全文并为一段」的兼容行为，
但会在段行里标 `unsplittable`/`oversized` 并打印 `RELAY_WARNING=`；当前 133 篇
固定文档中有 3 个这样的超长段（`message.txt`、`digraph.txt`、`index.txt`）。
`--lines` 与 `--upto` 必须是正整数，`--upto` 不得超过计划段数。

`assemble` 只在注入结果和整篇契约全部通过后，用同目录临时文件 + `os.replace()`
原子替换 `doc/<name>.cnx`；任何校验或写入失败都会保留原文件字节与权限。文档名必须
是 manifest 中登记的精确基名（拒绝绝对路径、`..`、目录分隔符），上游源文件还会按
固定 sha256 校验并拒绝符号链接。

`target()` 的取值优先级要注意：`doc/<name>.cnx` 存在时**优先**于
`doc/<name>.cnx.partial`。所以走查 `.partial` 流程（或任何想操作未完成文件的场景）必须
先在**副本**里把成品 `.cnx` 移开，否则 `verify`/`assemble` 实际操作的是成品文件，你会
得到与 `.partial` 无关的结论。仓库本身不得为此改名或删除任何文件。

## 分段模式（segment mode）：多段并行

上面「每次只有一篇文档、一个写入代理」的串行接力在只剩尾部时太慢。当一篇文档
已有 `doc/<name>.cnx.partial`（或 `.cnx`）且只差后面若干行时，可以把**剩余区间**
切成互不重叠的若干段，**每段一个代理并行**，各自写独立的**段文件**，由主代理统一
拼接。段文件不是 `.cnx`，所以不会被 `:helptags`/`tags-cn` 收录。

### 主代理

1. 切段：切点只能落在一个「行首顶格的空行且不在任何示例块内部」的位置，保证
   **不切开示例块**。给每段算出 `FROM-TO` 与预期 `blocks/tags/links`。
2. 派工：每段一个代理，产出 `doc/<name>.cnx.seg<NN>`（`<NN>` 两位，从 01 起，按
   FROM 升序）。
3. 每段回来后跑 `check-segment` 逐段验收；失败的段返工。
4. 全部 PASS 后按 `<NN>` 升序 `cat` 到已有的 `.partial` 末尾，再 `assemble` 注入块体。
5. 段文件在拼接后**立即删除**，仓库里不得留下 `*.seg*`。

### 代理

任务书给出 `<name>.txt`、`FROM-TO`、预期 `blocks/tags/links`、输出路径
`doc/<name>.cnx.seg<NN>`。代理只写这一个文件，产出格式与上面的骨架完全一致
（fence 行 + 顶格 `@@BLOCK@@`，块体一律不抄），并自检到 PASS：

    python3 tools/help_relay.py check-segment <name>.txt \
        --from FROM --to TO --segment doc/<name>.cnx.seg<NN>

`check-segment` 逐字节对照 **`skeleton(upstream[FROM-1:TO])`** 检查：tag 集合双向
一致、`|链接|` 计数一致、示例块数一致、placeholder 与 fence 行数一致、每个
`@@BLOCK@@` 的下一行必须是行首非空白字符的行（否则注入后块体会吞掉后面的散文）、
术语与编码。返回 `SEGMENT_CHECK=PASS` 才算完成；`SEGMENT_PROBLEM=` 逐条列出问题。

注意：段文件是**骨架**，不是最终译文——`@@BLOCK@@` 由主代理在拼接后用
`assemble` 注入上游块体。所以代理绝不手抄块体，也绝不自行注入。
