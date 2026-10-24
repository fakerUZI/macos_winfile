# 2026-10-24 压缩包成员使用默认应用打开

范围：main 工作区、本机 LeafFiles。本文记录提交前的功能验收，当时版本为 2.0.1 (14)；随后纳入 2.0.2，正式发行验证见 [2.0.2 发行验收](2026-10-24-release-2.0.2.md)。已有的单图标菜单改动保留。

## 行为

- 双击包内文件或点击「用默认应用打开」：仅临时解出所选文件，优先采用 LeafFiles 的自定义文件关联，未设置时查询 macOS 默认应用；保留原文件名、扩展名及中文路径。
- 外部打开严格要求原始大小小于 64 MiB。达到限制、大小未知或链接会提示先解压，并提供内置解压位置选择器入口；不启动应用。
- 空格及「查看所选文件」继续使用内置 Quick Look；单击不解压，文件夹双击仍进入目录。右上角原有「关闭」按钮保留。
- 外部副本只读，不会写回压缩包。缓存独立于归档工作区，关闭窗口不会立即删除外部应用正在读取的副本。同一归档预览会话重复打开复用；后续准备文件时回收超过七天或超出 512 MiB 目标的旧会话缓存。本次 LeafFiles 运行中已交付的文件受保护，容量目标不是硬上限。
- 密码、取消、原压缩包变化、未找到默认应用及应用启动失败都有对应处理。密码只留在内存。

## 验证

- 命令行逻辑回归：**1,259 项通过，0 失败**，`native/run_native_tests.sh --quick --cli-only --skip-device-tests`。
- 正式优化的 arm64 / x86_64 通用应用构建和代码签名校验通过；最终应用包在 arm64 上回归：**1,264 项通过，0 失败**，使用 `--run-tests --skip-device-tests`。本轮未在 Intel/Rosetta 下执行测试，未操作真实安卓设备。
- 新增回归覆盖：文本及 Markdown/PNG/MP4 扩展名交付、空文件、64 MiB 边界、未知大小、链接、重复打开复用、只读、关闭后保留、旧缓存回收、取消与关闭期间不启动外部应用、启动失败、加密重试、文件关联优先级及原压缩包变化。
- 修正命令行测试脚本遗漏的 `InterfaceStyle.swift` 依赖，并加入 `ArchiveOpenService.swift`。

## 真实界面

使用独立应用标识和生成的测试 ZIP，未打开个人文件内容：

1. Markdown 双击后在本机系统默认的 Notepad-- 中打开，中文内容正常，显示只读。
2. TXT 双击后在文本编辑中打开，文稿显示已锁定。
3. PNG 双击后在「预览」显示生成的 LeafFiles QA 图片。
4. MP4 双击后在 QuickTime Player 打开，点击播放，时间线前进；视频为生成的两秒 H.264 素材。
5. 64 MiB 稀疏文件双击显示「仅支持直接打开小于 64 MiB 的文件……请先解压再打开」，提供取消与「解压到…」。本轮未通过该提示执行解压。
6. 选择 TXT 按空格，仍在压缩包窗口内显示 Quick Look。关闭压缩包窗口后，文本编辑中已打开的文件仍可读取。

界面验收使用最终优化 arm64 可执行文件的独立 QA 应用副本。QA 应用和临时素材已删除，测试文档已关闭；截图、测试 ZIP 和日志保存在本机：

`/Users/mac/.codex/visualizations/2026/10/24/leaffiles-archive-default-open/`

包含 `archive-actions.png`、`extract-first.png`、`text-default-app.png`、`image-default-app.png`、`video-default-app.png`、`default-open-fixture.zip` 及构建/回归日志。

## 本机安装

已将最终签名通用应用安装至 `/Applications/LeafFiles.app`。安装后二进制 SHA-256 与验证构建一致，重新启动后恢复原有「压缩包」页签和个人收藏。旧应用备份：

`/Applications/.WinFile-backups/LeafFiles-before-archive-default-open-20261024-140434.app`
