# 发布检查清单

## 合入前

- [ ] 更新 `VERSION` 和 `CHANGELOG.md`。确认所有纳入发布的资源可从仓库重建。
- [ ] 使用固定 Neovim 运行 `make check-syntax check-translations check-native check-resources check-reproducible test release-check` 和离线 `make sync`。
- [ ] 运行固定上游的 `make test-upstream` 及改动所涉及的真实工作流。见[测试文档](docs/testing.md)与[工具链门禁](docs/toolchain-coverage.md)。
- [ ] 两次构建 SDK 2 附件并逐字节比较。检查目录中每项版本、URL、字节数和 SHA-256。
- [ ] 推送后核对同一提交的固定版离线测试、上游矩阵和平台探针。区分 PASS、FAIL、SKIP 与 BLOCKED。

## 发布

- [ ] 给通过检查的提交打主包 `vX.Y.Z` tag 和相应的 `packs-<id>-vX.Y.Z` tag。
- [ ] 发布各包 Release 附件，通过公开下载地址核对字节数与 SHA-256。
- [ ] 更新 `packs` 分支的 `catalog.json`，用新 Neovim 用户目录走一次实际在线安装。目录只指向可下载的附件。
- [ ] 发布主包 Release，附发行说明。用 tag 对应的源码验证安装与 `:checkhealth nvim-zh`。
- [ ] 下架附件前先从当前目录移除相应版本。保留 Git 历史与仍受支持的版本。
