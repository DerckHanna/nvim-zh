# 第三方插件适配

第三方适配的目标是改善常见交互，而不是追求插件数量。每个适配器只处理固定上游中能够证明来源和生命周期的显示文本；原始条目、回调参数、快捷键、路径、代码和用户数据仍由原插件拥有。

接入契约、上游更新机制与完整 TUI 门禁见[第三方插件中文适配系统设计](adapter-system-design.md)。

## 通用行为

- 默认只检查 `package.loaded` 中已经加载的模块，不为了汉化强制加载插件。
- `modules.plugins.auto = false` 关闭全部第三方适配；`disabled` 按名称关闭单个适配器。
- `lazy_load = true` 时使用 `User LazyLoad`，并在后续 Buffer/焦点边界补检已加载模块。
- 重复 setup 不叠加 wrapper。模块表被整体替换时按新代际重新接入；同一模块的函数被外部替换时报告 `external_override`，不抢回。
- 翻译目录更新用于后续自然调用。已经显示的边框、帮助 Buffer 或已创建 keymap 不会被强制重写。
- 使用通知标题路由的接缝通过精确 `opts.title` 和上游通知入口的来源匹配 domain。固定插件前缀及空白原样保留，标题碰撞时保留用户的原文。
- `status().adapters` 按插件和接缝报告活动状态、运行时证据和降级原因。

固定 commit、源码 SHA-256 和测试组合位于 `manifests/adapters/`。正式接口可以在其他满足契约的修订上工作，版本相关接缝需要加载源码证据。

### 启用版本相关接缝

先调用 `require('nvim-zh').setup()`，再加载目标插件。使用 `vim.pack` 且 `src` 与清单仓库地址一致时，适配器会识别实际加载目录，即使包名经过重命名。

```lua
require('nvim-zh').setup()
vim.pack.add({
  { src = 'https://github.com/nvim-lua/plenary.nvim' },
  { src = 'https://github.com/nvim-telescope/telescope.nvim',
    version = '1e1bab730218eaf97fce743be3f56e51075928ac' },
})
```

使用其他管理器或镜像时，在首次加载目标模块前调用
`require('nvim-zh').register_adapter_source('telescope', plugin_dir)`。若启用 `vim.loader`，应在设置 nvim-zh 前启用缓存加载器。

缺少加载证据或实际源码已经变化时，相关显示面使用上游文案。上游包更新后，可从 `:checkhealth nvim-zh` 查看哪些接缝需要重新加载，以及哪些接缝仍然可用。

## which-key

固定上游：`3aab2147e74890957785941f0c1ad87d0a44c15a`。

### 已接入

- 内置 operators、motions、text objects、windows、z、nav、g presets 的固定描述。
- marks/registers 的组名和固定含义，以及拼写建议入口。
- 自动生成的 keymap 数量、弹窗底部的关闭/返回/滚动、健康检查和常用中文帮助主题。
- 通过精确 `which-key.nvim` 通知标题路由的固定通知，保留 level、once、title 和 Markdown 通知行为。

原始 mapping、lhs/rhs/mode、buffer 和执行回调不被替换。用户 spec、寄存器内容、mark 路径和拼写建议词不属于目录数据。

### 边界

`replace.desc` 是公开显示接缝，但只收到字符串，没有条目来源。精确 msgid 避免了模糊替换，却不能排除用户自定义描述恰好等于内置文本时也显示译文；原始用户 mapping 不会被修改。状态中的来源说明保留这个限制。

底部提示、marks/Register 标签和健康报告依赖固定加载证据。图标、来源数据、用户分组描述和其余上游帮助主题可能继续显示英文。

## Telescope

固定上游：`1e1bab730218eaf97fce743be3f56e51075928ac`。

### 已接入

- 内置 picker 的 prompt、results 和初始 preview 标题。
- 默认 `Prompt` / `Results`、模糊精炼后的标题、按键映射浮窗标题和常用中文帮助主题。
- Git 分支操作及编辑 Register 的固定提示、选中项操作消息和健康报告。
- `Previewer:title` 的静态和动态标题；动态路径等未知值自然回退。
- 通过精确 `telescope.nvim` 通知标题路由的固定通知，保留 `[telescope.<function>]: ` 前缀、level、once 和 title。

初始标题在固定版本的 `telescope.pickers.window.get_initial_window_options` **显示投影**中翻译，而不是改写 `picker.prompt_title`。因此 picker 内部仍保留英文行为值，`to_fuzzy_refine` 对 `Live Grep` 和 `LSP Dynamic Workspace Symbols` 的英文判断不被破坏。

这是有意的版本相关接缝：固定源码证明它只生成窗口标题，真实上游契约同时验证显示结果和内部行为值。它不是对所有 Telescope 版本的兼容性承诺。

### 边界

- entry/display/ordinal/value、finder、sorter、previewer 对象、quickfix 内容和用户查询保持不变。
- `actions.generate.refine` 在上游完成分支判断后翻译显示标题，查询词沿用原值。上游直接抛出的 Lua 错误和 `Untitled` 搜索结果字段沿用上游。
- 已打开的静态 border 不随目录更新强制刷新；动态 preview 在下一次自然标题查询时使用当前目录。
- 空结果行和数字进度没有需要翻译的固定文本，不修改用户自定义 `get_status_text`。

## nvim-tree

固定上游：`dbc9d96a3633c2de85f409416ebd4a3aacf4220a`。

### 已接入

- 默认 `on_attach` 的固定 mapping 描述，包括无参 setup 和 lazy.nvim 先执行插件 setup、后发送 `LazyLoad` 的顺序。
- 通过精确 `NvimTree` 通知标题路由的固定通知；无 title 支持时的 `[NvimTree]` 前缀原样保留。

默认描述保留精确 ASCII `nvim-tree: ` 前缀，只翻译后缀；这同时保留帮助页对前缀的解析。lhs/rhs/buffer、默认执行函数和回调不变。

### 边界

- 文件操作选择与确认、文件信息、Window 选择、帮助浮窗和过滤统计使用固定上游接缝。用户自定义 `on_attach` 描述沿用原文。
- 已有 Buffer 的 keymap 不会在目录更新或普通 explorer 刷新后自动重建；重新 attach/创建时才使用当前译文。
- 插件载入时登记的 12 条用户命令描述，以及 `:NvimTreeHiTest` 的开发者诊断表头沿用上游。
- prompt/select 的原始 items 和回调值保持原样。没有可靠来源信息时，不把 Yes/No、文件名或路径塞进全局目录猜测翻译。

## nvim-dap

固定上游：`cfa2d58f4537aca6ca83e2de1a0d9f1491121264`。

### 已接入

- 通过精确 `DAP` 通知标题路由的固定通知，保留错误、路径、配置名、会话/线程 ID 和退出码等动态载荷。
- `dap.ui.pick_one` / `pick_one_sync` 的固定 prompt，以及具有 `fn` / `action` / `pid` 结构证据的动作和进程 label。原始 item、选择索引、回调和 coroutine 行为不变。
- REPL 新建 Buffer 时的固定 mapping 描述，以及真实 `.help` / `help` / `.h` 执行范围内的 `Commands:`、`Custom commands:`；栈帧列表的固定跳转提示。`dap> `、命令 token、补全项和调试器输出不翻译。
- 设置变量、设置表达式和异常断点筛选器的直接 `vim.fn.input` 提示。投影只存在于对应公开动作/同步调用内，输入值、默认值和后续 session 请求保持原样。
- `breakpoints.to_qf_list` 的显示副本：根据原始断点字段重建固定前缀，不解析或改写最终用户文本。原始 quickfix 列表、Buf/行列和 `DAP Breakpoints` 内部标题不变。
- `health.check` 的固定健康报告文本，以及合成线程根节点的 `Threads` 标题；动态适配器名、路径和会话数据不变。

### 边界

- 已有 REPL Buffer 的 prompt callback 和历史行不会重建；适配器只接入后续自然创建/执行的接缝。
- 插件加载时登记的 `DapNew` / `DapEval` 命令描述沿用上游。launch.json 的 `Input` 回退提示与用户显式描述重名时无法区分；用户描述和选项也沿用原文。
- quickfix 同一 Buf/行存在多个断点且无法无歧义对应原始字段时回退原文，避免错配条件或日志消息。
- Widget 的固定空状态、异常诊断前缀及部分启动与解析错误有中文投影。调试器返回的正文、变量/帧/线程名称、日志和进程输出沿用来源文字。

## nvim-dap-ui

固定上游：`cc9dd33aade7f20bae414d0cba163bc60d4d4b43`。

### 已接入

- 通过精确 `nvim-dap-ui` 通知标题路由的固定通知，动态元素名、表达式和错误载荷保留原值。
- 固定版本 `Canvas.write` 显示投影，只处理 `DapUIBreakpointsInfo`、`DapUIWatchesEmpty`、`DapUISource` 三类高亮下的固定标签/占位文本。高亮位置按中文新字节宽度由原实现重新计算。
- Buffer 局部 mapping 的描述、浮窗默认元素标题、元素选择器的 prompt/label、值截断后的固定行数后缀，以及无活动会话等合成状态文本。
- 默认 `select_window` 路径的同步 `print("Select window: ")` 投影。自定义 `config.select_window` 不包装，原始 Window id 和按键选择逻辑不变。
- 无参 setup、重复 setup、晚加载和模块表换代；首次自然 render 即使用中文，不为了汉化强制加载插件。

共享 `nio.ui.select` 只有在 DAP UI 已完成 setup、候选项恰好是六个内置非 hover 元素 ID、且原 formatter 产生预期标签时才投影显示文本。原始 item、选择索引和回调结果不变；同 prompt 的其他选择器不命中。

### 边界

- 不扫描或重写已有 Buffer；目录更新后的文本在下一次自然 render 时生效。`DAP Scopes` 等 Buffer 名是查找身份，不作为标题翻译。
- 变量、作用域、表达式、栈帧、线程、路径、调试器输出和 DAP 协议数据保持原样。只有经过结构条件确认的固定合成文本进入目录。
- 依赖缺失、布局/注册错误等抛出值不属于显示投影，保持英文；图标本身和没有固定 hover 文案的 controls 不制造翻译。
- 默认 Window 选择的 print 包装是固定版本同步接缝，异常、重入和外部替换按所有权恢复；不接管全局消息 UI。

## nvim-dap-view

固定上游为 `1c3b9cc295303fc173f24d442739a8557e23e987`。

- 默认视图标签和按键描述随面板创建。例如只把变量视图的键改为 `L`，标签显示为「变量 [L]」。显式标题、动态标题函数、自定义视图和分区键使用 `dap-view.setup()` 提供的配置。
- 面板和悬浮求值的空状态、`g?`、输入与跳转选择、通知和配置错误在上游显示时翻译。DAP 错误正文、自定义格式、用户输入和回调收到的数据保留来源值。使用 Neovim 原有的通知去重键。
- 未配置边框时，中文 `g?` 浮窗使用单线边框显示标题。显式的 `help.border` 和 `'winborder'` 优先。
- CodeLLDB 的四个作用域、寄存器分组和 C++ 异常标签使用中文。作用域和异常选项以已启动的 `codelldb` 可执行文件及对应 DAP 字段确认来源。折叠状态、DAP 引用、过滤器 ID 和请求使用原始数据。其它适配器或无法确认来源的命令沿用原标签。
- 固定版本在异常条件虚拟行使用了 Neovim 0.12.6 不接受的 `wrap` 参数。已验证加载路径采用该版本支持的 `scroll`，因此在中文和英文模式都能显示条件和示例。
- `:help dap-view.txt` 和各主题标签提供与固定英文原文对应的全文翻译。
- 在首次 `require('dap-view')` 前启用 `nvim-zh` 或登记源码目录，让加载器记录源码证据。首次 `F5` 自动打开面板和手动 `:DapViewOpen` 共用显示入口。已有 Buffer、已创建映射和已打开浮窗在自然重建时采用新的语言设置。

## lazy.nvim 与 nvim-cmp

- lazy.nvim 提供 `User LazyLoad`，用于发现受支持插件。Lazy 主面板、安装进度、插件自有通知和 Help 沿用上游。
- nvim-cmp 固定版本的审查仍未找到可证明由 cmp 自己拥有、且不会触及 completion item/source 的固定标签，保持 `inventory_only`。不翻译 abbr、kind/menu、文档或用户 formatter 数据。

## 新增适配器的要求

1. 在 `lua/nvim-zh/adapters/` 新建一个模块，并在 `manifests/adapters/<id>.json` 声明入口。使用 `make build-resources` 更新生成索引与发布资源。
2. 固定完整上游 commit，记录实际检查源码 hash 和公开/版本相关接缝依据。
3. 编辑对应 domain 的 PO，使用稳定 context 和真实 source reference；不从 fixture 编造产品条目。
4. 先写差分和负向契约，再实现。至少覆盖默认流程、重复 setup、晚加载、外部替换、模块换代、未知文本和 teardown。
5. 真实上游 smoke 与离线测试分离；缺固定源码时，显式 upstream 入口必须失败而不是以 SKIP 冒充通过。
