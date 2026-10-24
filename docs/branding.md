# LeafFiles 名称与更新兼容

应用对外名称为 **LeafFiles**，原名 WinFile。中英文界面、Dock、应用菜单、关于页面及系统权限说明均使用新名称。

现有一键安装命令继续沿用：

```bash
curl -fsSL https://raw.githubusercontent.com/fakerUZI/macos_winfile/main/install.sh | /bin/bash
```

为让现有安装继续更新，以下兼容标识保留：

| 项目 | 保留的值 |
| --- | --- |
| 仓库 | `fakerUZI/macos_winfile` |
| 安装脚本 | 主分支的 `install.sh` |
| 应用目录与执行文件 | `LeafFiles.app/Contents/MacOS/WinFile`（执行文件保持兼容名称） |
| 应用标识 | `local.winfile.mac` |
| 通用下载文件 | `WinFile.zip`、`WinFile.zip.sha256` |
| 版本化更新包 | `WinFile-<version>.zip` |
| 自动更新源 | 最新稳定版 Release 的 `appcast.xml` |
| 更新签名 | 现有 Ed25519 公钥与钥匙串签名账号 |
| 本机设置与数据 | 现有收藏、会话、默认打开方式、缓存与日志位置 |

安装目录现统一为 `LeafFiles.app`，访达显示 LeafFiles。安装脚本同时接受旧版 `WinFile.app` 与新版 `LeafFiles.app` 压缩包，成功后将旧应用移入备份目录，失败时恢复原路径。下载资产与内部执行文件仍保留 WinFile 兼容名称，个人设置无需迁移。

从 v2.0.0（构建号 13）起，正式发行包使用 LeafFiles 显示名称。更新沿用原有签名密钥与更新源；后续发布仍需递增版本号和构建号。

从 v2.0.1（构建号 14）起，归档中的应用目录为 `LeafFiles.app`。Sparkle 能通过既有应用标识识别新包，但应用内更新可能保留旧安装目录名。需要统一访达目录名时，退出应用后再次运行上述 curl 命令；安装脚本将备份旧目录并迁移。
