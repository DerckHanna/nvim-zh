# 发布检查清单

提交、推送、打 tag 和发布由维护者决定。

- [ ] 确认 `VERSION`、`CHANGELOG.md` 与目标版本一致，发布版号遵循 semver。
- [ ] 运行 `make check-syntax check-translations check-native`，处理所有语法、PO、术语和清单错误。
- [ ] 运行 `make build-resources check-resources`，确认完整 `resources/` 与编辑源一致；安装端没有构建 hook。
- [ ] 运行 `make test`，覆盖默认离线契约、配置自动生效、真实 PTY、vim.pack 确认/取消/更新/损坏资源/回退及并发。
- [ ] 运行 `make check-reproducible`，确认 Lua、MO 与完整资源无时间戳且逐字节一致。
- [ ] 准备 manifest 固定 commit 的第三方源码，运行 `make test-upstream`；缺少固定源码必须视为未完成，不接受 SKIP 冒充通过。
- [ ] 按 `docs/testing.md` 的显式入口运行可用的真实 native/clangd 检查，逐项记录 PASS、FAIL、SKIP 和受阻原因。
- [ ] 固定 Clang 工具链按 `docs/toolchain-coverage.md` 重建盘点和三个候选附件，使用同一项目取得启停对照与原始协议，并运行 `tools/toolchain_coverage.py --require-complete`。检查词条、歧义、分析器盘点与方法证据，完整门禁通过后登记该组合。
- [ ] 运行 `make release-check`，检查临时候选包。处理零字节文件、缓存、临时件、日志与研究下载。
- [ ] 运行离线 `make sync`。如需联网，只用显式入口 `make sync-fetch` 或 `make sync-native`，并审查全部变化；`make sync --fetch` 不是合法调用。
- [ ] 同机比较两份大包启动、GC 后 RSS、词库首用和诊断及列表 P95。核对离线选版、损坏回退和同版本不同摘要。
- [ ] 从当次命令输出记录覆盖范围、运行时观察、可选检查和性能读数，不沿用旧数字，不把 fixture 命中率写成整体汉化率。
- [ ] 检查发布包不包含 `.git`、测试临时件、缓存、研究源码、散落备份或日志；项目文档没有陈旧 PASS、旧入口或阶段性进度叙述。
- [ ] 推送后核对同一提交的 GitHub Actions。通过固定版离线和上游测试后，由维护者决定是否打 tag 和发布。
