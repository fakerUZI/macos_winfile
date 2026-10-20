# 自动更新

此功能从 v1.2.0 起提供。v1.1.0 及更早版本没有更新器，需先通过 Releases 或一键安装脚本升级一次。只有新版应用和签名更新源都发布后，用户才能收到后续更新。

## 用户体验

- 默认每次正常启动检查 GitHub 最新稳定版。发现未跳过的新版本时，显示 Sparkle 原生 macOS 更新窗口，提供「安装更新」「跳过这个版本」「稍后提醒我」。
- 「稍后提醒我」保留当前版本，下次启动再次检查。「跳过这个版本」记住该版本；之后的新版本仍会提醒。应用菜单或「设置 → 关于 → 检查更新」可手动查看已跳过的版本。
- 点击安装后下载发行包、校验签名、解压；就绪时确认「安装并重新启动」，由更新器替换应用并重启，无需执行 git、安装 Xcode 或手动拖放。
- 「设置 → 通用」可关闭启动检查。无更新或网络不可用时，启动检查保持安静；手动检查会展示结果或错误。
- 正在复制、移动、安卓传输、解压或执行空间清理（含微信附件、通用清理和其他软件缓存）时，安装重启等待操作结束，避免主动中断文件任务。
- 更新包只替换应用本身，设置和文件继续保留。权限不足时可能需要 macOS 管理员授权。

## 更新来源与验证

使用 [Sparkle 2.10.0](https://sparkle-project.org/documentation/)，最低 macOS 13，支持 Apple Silicon 与 Intel。

更新源：`https://github.com/fakerUZI/macos_winfile/releases/latest/download/appcast.xml`。源中的安装包 URL 固定到对应的 `v版本号` Release，不随 `latest` 改变。应用使用固定 Ed25519 公钥验证更新源与安装包，安装包在解压前验证；签名源校验失败不回退到无签名模式。关闭系统信息上报和静默自动安装。

应用的 ad-hoc / Developer ID 代码签名和更新包的 Ed25519 签名用途不同；更新签名不能替代 Apple 公证。当前仍未完成 Developer ID 公证，首次安装请遵循 README 的说明。

## 维护者发布步骤

1. 同时递增 `native/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。后者为递增的整数，用于更新比较。
2. 编写 `docs/releases/v版本号.md`，运行测试，然后执行：

   ```bash
   ./native/make_release.sh
   # 若刚完成构建，也可使用已验证的干净构建：
   ./native/make_release.sh --package-only
   # 使用公钥验证真实发行文件，并验证篡改会被拒绝：
   python3 tools/test_update_package.py
   ```

   构建脚本将应用组装和签名于系统临时目录，避免同步目录/Finder 元数据破坏签名；`native/native-build/last-built-app-path` 记录该路径。打包前校验包的版本、构建号和代码签名，使用官方 `generate_appcast` 签名，再仅用公钥验证源与压缩包。临时目录被清理时重新构建即可。
3. 在 GitHub 创建对应 `v版本号` 的稳定版 Release，同时上传 `dist/` 中以下五个文件：

   - `appcast.xml`
   - `WinFile-版本号.zip`
   - `WinFile-版本号.zip.sha256`
   - `WinFile.zip`
   - `WinFile.zip.sha256`

   前两个供应用更新，稳定名称兼容一键安装脚本。不要只上传 XML 或只更新稳定名称的 ZIP。脚本只生成本地文件，不会自动推送、创建或发布 Release。GitHub 草稿/预发布不会被此 `latest` 更新源选中。

4. 从上一版本验证实际下载、安装和重启，再对外说明新版本已可用。维护者应保留每个版本号的不可变发行包；不要复用构建号或用旧构建覆盖最新稳定版。

### 密钥

生产更新密钥的 Keychain account 为 `local.winfile.mac`，私钥仅保存在发布机登录钥匙串。应用内固定公钥为：

```
3AbK+TOpDBmTgWNtsch3Xs0w0YgzzOiYtMdIv800Za8=
```

公开仓库、发行包、日志或 CI 中不得放入私钥。构建和公钥验证不需要私钥；正式打包签名需要原密钥及钥匙串授权。换发布机器时先安全迁移并核对同一密钥；不要重新生成一把不同的密钥替代它。私钥丢失时，现有客户端无法验证新密钥签名的更新，必须安排手动升级或按 Sparkle 官方流程迁移。

SDK 的版本、下载地址和 SHA-256 固定在 `native/prepare_sparkle.sh`，许可和来源位于 `native/vendor/sparkle/`。二进制依赖、应用、ZIP 及临时测试源均不入库。

## 本地验证记录

此次构建的命令行测试 771 项通过，arm64 与 x86_64/Rosetta 应用包分别 776 项通过；跳过真实安卓设备文件操作。独立测试应用通过本地签名源完成 1.0.0 → 1.0.1 的下载、验证、替换与重启，保留原设置；启动提醒、稍后提醒、跳过及手动恢复检查均已验证，篡改源被客户端拒绝。另有四项发行文件签名回归测试验证有效签名、篡改安装包、篡改源和伪造签名长度。安装测试未覆盖需要管理员提权的用户安装目录。
