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
| 应用目录与执行文件 | `WinFile.app/Contents/MacOS/WinFile` |
| 应用标识 | `local.winfile.mac` |
| 通用下载文件 | `WinFile.zip`、`WinFile.zip.sha256` |
| 版本化更新包 | `WinFile-<version>.zip` |
| 自动更新源 | 最新稳定版 Release 的 `appcast.xml` |
| 更新签名 | 现有 Ed25519 公钥与钥匙串签名账号 |
| 本机设置与数据 | 现有收藏、会话、默认打开方式、缓存与日志位置 |

因此，界面中显示 LeafFiles，而实际路径或下载文件仍包含 WinFile，是兼容设计，无需移动应用或迁移设置。

从 v2.0.0（构建号 13）起，正式发行包使用 LeafFiles 显示名称。更新沿用原有签名密钥与更新源；后续发布仍需递增版本号和构建号。
