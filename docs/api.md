# Lua API

公共入口只有 `require('nvim-zh')` 暴露的函数。其他 `nvim-zh.*` 模块属于内部实现，不作为稳定插件接口。

普通查询不会隐式执行 setup、联网、安装、更新、生成 locale 或写入资源缓存。返回的配置和状态快照是副本，修改它不会改变插件状态。

## `setup(opts?)`

```lua
local zh = require('nvim-zh').setup()
```

校验并应用配置，返回主模块。重复调用会更新基础配置，再与本地 JSON 合并；不会叠加 wrapper、autocmd 或后台任务。配置项见[配置文档](configuration.md)。

实现代码更新不会通过 setup 强制热执行；需要重启时，`status().runtime.restart_required` 为 `true`。

## `status()`

```lua
local snapshot = require('nvim-zh').status()
```

返回结构化只读快照，主要字段如下：

| 字段 | 内容 |
|---|---|
| `configured` | 是否已成功应用 setup 配置 |
| `config` | 当前有效配置的深拷贝 |
| `version` | 运行版本、磁盘安装版本、实现标识、活动/安装资源集和资源摘要 |
| `runtime` | 同步状态、错误、代次、待重启状态和本地配置文件状态 |
| `native` | gettext 绑定、消息语言、MO 路径、平台降级原因 |
| `help` | 中文 Help 路径、索引与 `'helplang'` 状态 |
| `ui` | notify、input/select、select_items、echo 的启用/活动/原因 |
| `plugins` | 各第三方适配器的 `enabled/active/reason/seam` |
| `diagnostics` | 各诊断显示接缝与本进程实际观察 |
| `lsp` | clangd 消息和进度 handler 状态 |
| `nvim_version` / `v_lang` / `helplang` | 当前 Neovim 与语言状态 |

`version.running_implementation` 与 `version.installed_implementation` 不同，表示磁盘实现已变化；不能据此认为当前进程已经执行新代码。

常见状态原因包括 `disabled`、`not_loaded`、`unsupported_api`、`external_override`、`degraded`、`unsupported` 和 `restore_failed`。未检查与不通过是不同状态。

## `translate(spec)`

```lua
local text, status, entry_id = require('nvim-zh').translate({
  domain = 'my-plugin',
  context = 'menu', -- 可省略，默认 ''
  msgid = 'File {name}',
  args = { name = 'demo.lua' },
})
```

输入字段：

- `domain`：必填目录名。
- `context`：可选字符串，用于区分多义词和使用场景。
- `msgid`：必填原始英文文本。
- `args`：命名模板使用 Table；printf 模板使用保持原顺序和类型的数组。
- `formatted = true`：`msgid` 已包含动态值时，仅匹配目录中锚定且转义的受控模板。
- `translated = true`：调用方明确声明文本已经翻译，跳过再次翻译。
- `observe = false`：内部差分适配使用，不把一次上下文试探记为独立用户观察。

返回 `text, status, entry_id`；`status` 为 `translated` 或 `fallback`。未知文本、歧义、非法参数、目录错误和规则异常均回退原始 `msgid`，不做模糊猜测。

## `register_catalog(domain, loader, metadata?)`

```lua
require('nvim-zh').register_catalog('my-plugin', function()
  return {
    schema = 1,
    domain = 'my-plugin',
    locale = 'zh_CN',
    entries = {
      { context = '', msgid = 'Save', msgstr = '保存' },
    },
  }
end, { source = 'my-plugin/l10n' })
```

注册懒加载目录，成功返回 `true`。domain 必须合法且不能重复注册，loader 必须是函数，metadata 必须是 Table。loader 返回的目录会经过 schema、domain、locale、空译文和重复键校验；用户覆盖在内置条目之后合并。

`refresh()` 会使已注册目录在下次使用时重新加载。外部 loader 自己的依赖缓存仍由调用方管理，插件不会清空整个 `package.loaded`。

## `stats()`

```lua
local stats = require('nvim-zh').stats()
```

返回：

- `static.domains`：当前已加载目录及其条目数；未加载目录不会为了统计而被强制加载。
- `runtime`：当前进程中，通过已接入入口观察到的 `observed/translated/fallback`、去重记录和淘汰状态。
- `missing`：缺失记录条数、回退次数、容量和开关。

这些数字不是全 Neovim、整个第三方插件或整个语言服务器的汉化率。固定 fixture 的命中统计只属于相应测试，不进入运行时覆盖率。

## `missing()`

```lua
local rows = require('nvim-zh').missing()
```

返回按出现次数排序的脱敏记录。每行包含 `domain/context/key/msgid/count/dynamic`；动态文本、路径和超长原文使用摘要标签。记录只保存在当前进程。

## `open()`

```lua
local win, err = require('nvim-zh').open()
```

打开或聚焦只读中文面板，成功返回 Window id。没有 UI 时返回 `nil, err`，不会创建不可见窗口，也不会触发资源同步。面板操作见 `:help nvim-zh`。

## `check(callback?)`

```lua
local id = require('nvim-zh').check(function(result)
  if result.status == 'ok' then
    vim.print(result.results)
  end
end)
```

启动只读健康检查并返回任务 id。回调字段包括：

- `ok`：检查流程是否成功完成；单项警告仍属于成功完成的检查。
- `status`：`ok`、`degraded`、`error` 或 `cancelled`。
- `task_id`：与返回值对应的任务 id。
- `results`：成功时的结构化检查项，各项含 `name/status/message`。
- `error_code` / `error`：失败或取消原因；取消可为 `superseded` 或 `stopped`。

再次调用会使尚未完成的旧检查明确取消，最新结果写入检查快照。`:NvimZhCheck` 和 `:checkhealth nvim-zh` 使用同一检查能力，但分别提供同步文字输出和 Neovim 标准健康界面。

## `refresh(callback?)`

```lua
local id = require('nvim-zh').refresh(function(result)
  vim.print(result.status, result.error)
end)
```

重新协调本地配置、已注册翻译目录和当前已安装资源，返回任务 id。**它不会联网、下载、修改 vim.pack 锁文件或选择另一个修订，也不是手动更新入口。**日常更新直接使用 `vim.pack.update()`，通常不需要调用此函数。

回调字段包括 `ok/status/error_code/error/restart_required/task_id`：

- `ok`：资源与配置成功应用，原生模块不受支持时可为 `degraded`。
- `degraded`：兼容资源已应用，但至少一个能力明确降级。
- `error`：候选或应用失败，已保留/恢复上一份有效状态。
- `cancelled`：teardown 或停止流程取消的任务。

忙碌时重复请求合并到同一协调队列；回调在最终完成或取消时收到结果，而不是把“已排队”误报为“已生效”。

## `teardown()`

关闭面板，停止计时器、订阅和可取消任务，恢复仍由本插件拥有的 UI、诊断、LSP、第三方适配和原生进程状态。外部后来替换的函数、gettext 绑定或消息语言不会被抢回。

## 状态变化事件

同步或适配状态变化后触发：

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'NvimZhChanged',
  callback = function(event)
    -- event.data: schema, generation, reason
  end,
})
```

事件数据不包含原始配置或未脱敏文本。监听者不应在回调中无条件再次请求同步，以免形成事件循环。
