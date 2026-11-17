# 发布检查清单

发布是人工操作；自动化不得自行打 tag、推送或发布。

- [ ] 确认目标版本号遵循 semver，CHANGELOG 与兼容表和实际能力一致。
- [ ] 在本机必过版本运行 `make test` 和 `make check-translations`。
- [ ] 运行 `make check-reproducible`，确认 PO→Lua 无时间戳且字节一致。
- [ ] 运行 `make release-check` 检查排除工作树 `.git` 后的临时候选包，处理所有零字节、缓存、临时件、日志与研究下载。
- [ ] 单独运行固定完整 commit 的真实上游 smoke，记录每个结果和 SKIP。
- [ ] 运行离线 `make sync`；如需联网，只用显式入口 `make sync-fetch`（UI 目录）或 `make sync-native`（核心消息）并审查变化——`make sync --fetch` 不是合法调用，`--fetch` 属于工具参数。
- [ ] 从实际命令输出记录静态条目、运行时观察覆盖率与性能，不沿用旧数字。
- [ ] 检查发布包不包含 `.git`、测试临时件、缓存、研究源码、散落备份或日志。
- [ ] 由维护者人工决定 tag/发布；本次任务未执行这些操作。
