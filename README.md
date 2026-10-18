# WinFile

**macOS 上的 Windows 风格文件管理器**，用原生 SwiftUI 实现。

[English](README.en.md) | **简体中文**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13.0%2B-black.svg)](#安装)
[![Swift](https://img.shields.io/badge/Swift-5-orange.svg)](#技术栈)
[![Tests](https://img.shields.io/badge/tests-382%20passing-brightgreen.svg)](#测试)
[![Release](https://img.shields.io/badge/release-v1.0.0-blue.svg)](../../releases/latest)

习惯 Windows 资源管理器的人切换到 macOS，常会觉得访达少了几样东西：页签、路径栏、按类型分类、能直接看到某个文件夹有多大。WinFile 把这些补回来，同时保持原生的外观与性能。

![主界面](docs/screenshots/main-window.png)

---

## 目录

- [为什么做这个](#为什么做这个)
- [功能](#功能)
- [安装](#安装)
- [从源码构建](#方式二从源码构建)
- [测试](#测试)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [许可证](#许可证)

## 为什么做这个

访达很好，但它刻意做减法。日常整理文件时，有些需求它没有直接答案：

- 想在一个窗口里开多个页签，各自停在不同目录
- 想按「图片 / 视频 / 文档 / 压缩包」直接浏览，而不是先记得文件在哪个文件夹
- 想知道某个文件夹到底占了多少空间
- 想看看微信、小红书这些应用把文件存在了哪
- 想在 Mac 上管理安卓平板里的文件

WinFile 不试图取代访达，而是补上这些空白。它**不开沙盒**，因此可以浏览整个磁盘——包括其它应用的数据目录，这是它和 App Store 应用最大的区别。

## 功能

### 浏览与导航

| 功能 | 说明 |
| --- | --- |
| **多页签** | 一个窗口内多个页签，各自独立的目录、历史、排序与选择；支持 `⌘T` 新建、`⌘W` 关闭、右键「关闭其它 / 复制标签页」 |
| **路径栏** | 面包屑显示当前路径，双击可输入；支持 `~`；输入时实时给出候选，`Tab` 补全、`↑↓` 选择、`Enter` 跳转 |
| **两种视图** | 详细信息表格（可按名称/日期/类型/大小排序）与大图标网格 |
| **按类型分类** | 图片、视频、音乐、文档、表格、演示文稿、PDF、压缩包、代码、电子书、设计素材、数据库、字体、磁盘映像、可执行文件，共 15 类，带数量徽标 |
| **搜索** | 在当前文件夹内递归按名称搜索 |
| **深色模式** | 全部使用系统语义颜色，自动跟随 |

### 文件操作

| 功能 | 说明 |
| --- | --- |
| 基础操作 | 打开、重命名、新建文件夹 / 文本文档、制作副本、复制 / 剪切 / 粘贴、拖放、移到废纸篓 |
| **压缩 / 解压** | 压缩为 zip（中文文件名不乱码）；解压 zip / tar / tgz / gz / bz2 / xz，先解到临时目录再合并，同名冲突自动改名为「\<包名\> 解压」，**全程零覆盖** |
| **缩略图** | 大图标视图下显示真实预览：图片、视频封面帧、PDF 首页（由系统 QuickLook 生成，带缓存） |
| **打开方式** | 列出系统里真正能打开该文件的应用，支持搜索过滤；可在应用内指定默认应用（**不影响 macOS 系统关联**）；文件图标右下角显示关联应用徽标 |
| **复制为** | 复制完整路径 / 文件名 / 所在目录；`⌘C` 同时写入系统剪贴板，可直接粘贴到其它应用 |

### 特色页面

| 页面 | 说明 |
| --- | --- |
| **主页** | 快速访问磁贴、收藏夹、最近使用（最近修改 + 应用内打开过的文件，带标记，可清除记录） |
| **此电脑** | 驱动器卡片，带容量进度条（>75% 变橙、>90% 变红）、已用 / 可用 / 总容量、文件系统类型；可移动盘可弹出 |
| **应用程序** | 聚合 `/Applications`、`/System/Applications`，使用系统真实图标 |
| **应用数据** | 扫描各应用的数据容器，快速进入其它应用（如微信）的文件目录；自动去掉空壳容器并还原真实应用名 |
| **安卓设备** | 通过 adb 浏览安卓设备：列表、上传、下载、新建、重命名、复制 / 移动、删除，多台设备按序列号区分 |

### 界面细节

- **空白处右键菜单**：对齐 Windows 资源管理器——新建、粘贴、排序方式、视图方式、显示隐藏文件、在访达中显示、复制当前路径
- **侧边栏可管理**：分类与收藏支持右键移动 / 移除，也可在「管理侧边栏」面板里用多选框勾选并排序
- **状态栏与检查器**：显示项目数、选中项大小、磁盘可用空间；检查器显示单个文件的详细信息

## 安装

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 13 (Ventura) 或更高 |
| 架构 | Apple Silicon 或 Intel（通用二进制） |
| 安卓功能（可选） | `brew install android-platform-tools` |
| 源码构建（可选） | Xcode Command Line Tools，`xcode-select --install` |

不需要完整 Xcode，也不需要付费 Apple 开发者账号。

### 方式一：下载安装包

从 [Releases](../../releases/latest) 下载 `WinFile-1.0.0.zip`，解压后把 `WinFile.app` 拖到「应用程序」。

**首次打开会被 macOS 拦截**，提示「已损坏，无法打开」或「无法验证开发者」。这是**未签名、未公证**应用在 macOS 上的正常提示，文件本身没有损坏。执行一次即可放行：

```bash
xattr -dr com.apple.quarantine /Applications/WinFile.app
open /Applications/WinFile.app
```

也可以在「系统设置 → 隐私与安全性」底部找到被拦截的提示，点「仍要打开」。

> 新版 macOS 已不再支持「右键 → 打开」绕过，请用上面的方式。

### 方式二：从源码构建

在自己机器上构建的产物**不携带隔离属性**，不会触发上面的拦截。

```bash
git clone https://github.com/fakerUZI/macos_winfile.git
cd macos_winfile

./native/build_native.sh            # 构建并安装到 /Applications
./native/build_native.sh --in-place # 只构建到项目目录
```

构建脚本会依次：生成图标 → 编译 arm64 与 x86_64 → 合并为通用二进制 → 组装应用包 → 复制中英文本地化 → 签名（无身份时用 ad-hoc）→ 安装并登记。

### 安卓功能准备

```bash
brew install android-platform-tools
```

在平板上开启「开发者选项 → USB 调试」，用数据线连接后在弹窗中点「允许」。应用启动时会自动扫描设备，侧边栏出现「安卓设备」。

> macOS 没有 MTP 的系统支持，因此安卓文件访问通过 adb 实现，是本项目**唯一**使用子进程的部分；本地文件操作全部走原生 API。

## 测试

```bash
./native/run_native_tests.sh
```

依次执行三种模式：命令行逻辑测试 → 真实应用包内测试 → 界面冒烟测试。若连接了已授权的安卓设备，还会跑一遍真实的设备文件操作测试。

当前状态：**382 项通过**。

应用二进制本身也内置了验证入口：

```bash
./WinFile.app/Contents/MacOS/WinFile --run-tests
```

## 项目结构

```
macos_winfile/
├── native/
│   ├── WinFile/                        # SwiftUI 源码
│   │   ├── WinFileApp.swift            #   入口、菜单栏、命令
│   │   ├── MainView.swift              #   主界面（侧边栏/页签/命令栏/地址栏/检查器）
│   │   ├── SidebarView.swift           #   导航侧边栏（支持右键移动/移除）
│   │   ├── SidebarManagerSheet.swift   #   侧边栏管理面板（多选框 + 排序）
│   │   ├── SidebarPreferences.swift    #   分类的显示与顺序（持久化）
│   │   ├── FileViews.swift             #   详细信息表格、大图标网格、图标与徽标
│   │   ├── InspectorView.swift         #   详细信息窗格
│   │   ├── HomeViews.swift             #   主页 / 此电脑
│   │   ├── TabManager.swift            #   多页签管理
│   │   ├── ActiveTabReader.swift       #   让界面跟随当前页签的模型
│   │   ├── ContextMenuCatcher.swift    #   空白处右键（AppKit 命中判定桥接）
│   │   ├── Dialogs.swift               #   重命名 / 新建 / 打开方式
│   │   ├── SettingsView.swift          #   设置（通用/侧边栏/打开方式/诊断）
│   │   ├── PathField.swift             #   路径输入框（Tab 补全）
│   │   ├── Models.swift                #   条目模型与文件类型库
│   │   ├── FileSystemService.swift     #   无状态文件 I/O（可后台执行）
│   │   ├── ArchiveService.swift        #   压缩 / 解压
│   │   ├── ThumbnailService.swift      #   QuickLook 缩略图（图片/视频/PDF）
│   │   ├── FileAssociations.swift      #   应用内默认打开方式（不改系统设置）
│   │   ├── DefaultAppService.swift     #   关联应用解析与徽标图标缓存
│   │   ├── FSEngine.swift              #   收藏、图标、废纸篓、Launch Services
│   │   ├── AppDataService.swift        #   应用数据目录扫描
│   │   ├── AppDataView.swift           #   应用数据页面
│   │   ├── BrowserModel.swift          #   浏览状态（导航/排序/选择/剪贴板）
│   │   └── Android/                    #   安卓设备支持（adb 封装）
│   ├── WinFileTests/                   #   测试套件（382 项）
│   ├── Resources/                      #   中英文本地化
│   ├── Info.plist                      #   应用元数据
│   ├── build_native.sh                 #   构建脚本
│   ├── run_native_tests.sh             #   测试脚本
│   └── make_release.sh                 #   发布打包脚本
├── docs/                               # 图标与截图
├── tools/make_icon.py                  # 图标生成（构建时自动调用）
├── LICENSE
└── README.md
```

构建产物 `WinFile.app/` 与发布包 `dist/` 不入库，可由脚本重新生成。

## 技术栈

| 方面 | 采用 |
| --- | --- |
| 界面 | SwiftUI（`NavigationSplitView` / `Table` / 自建网格），AppKit 用于菜单、剪贴板、Launch Services 桥接 |
| 文件 I/O | `FileManager` + `URLResourceKey`，写操作放到后台线程 |
| 压缩解压 | 系统自带 `zip` / `ditto` / `bsdtar` |
| 缩略图 | QuickLook（`QLThumbnailGenerator`），图片 / 视频封面 / PDF 首页 |
| 图标 | `NSWorkspace.icon(forFile:)`，保留系统图标与 Assets.car 内图标 |
| 安卓 | `adb` 子进程（唯一使用子进程的部分） |
| 本地化 | `Localizable.strings`（简体中文 / 英文），代码内联回退文案 |
| 构建 | `swiftc` 直接编译，无需 Xcode 工程；`lipo` 合并通用二进制 |

## 常见问题

**为什么打开时提示「已损坏」？**

应用没有 Apple 开发者签名、也没有公证，macOS 因此拦截。这不是文件损坏，按[安装](#方式一下载安装包)里的 `xattr` 命令放行一次即可。

**为什么不发布到 App Store？**

App Store 要求沙盒，而沙盒会**永久阻断**读取其它应用的数据目录——这恰好是本项目的核心功能之一。同时上架需要付费开发者账号（99 美元/年）。因此本项目选择本地使用形态。

**为什么安卓不用 MTP？**

macOS 没有 MTP 的系统支持，也没有为第三方应用提供 MTP 接口。Windows 把 MTP 做进了资源管理器，macOS 没有对应物。因此安卓访问只能通过 adb。代价是需要开启 USB 调试；好处是可以访问 `Android/data` 等 MTP 访问不到的位置。

**为什么有些系统目录显示「无权限访问」？**

macOS 用 TCC 保护部分目录（如 Safari 容器）。即使授予「完整磁盘访问权限」，仍有个别目录不可读，属系统限制。

**打开方式改了会影响系统吗？**

不会。应用内设置的默认打开方式**只存在 WinFile 自己的配置里**，不会调用任何系统级关联 API，访达与其它应用的行为保持不变。

## 已知限制

| 事项 | 说明 |
| --- | --- |
| 首次打开拦截 | 未签名 / 未公证，需按安装说明放行一次（源码构建无此问题） |
| 安卓功能 | 必需 adb；需在设备上开启 USB 调试 |
| 系统目录权限 | 少数受 TCC 保护的目录不可读 |
| 尚未实现 | 标签颜色、批量重命名、网络位置（SMB/FTP）浏览 |

## 许可证

[MIT](LICENSE) © 2026 曹聪 (fakerUZI)

可自由使用、修改、分发与商用，仅需保留版权声明与许可声明。

---

如果这个项目对你有帮助，欢迎 Star。有问题或建议可以提 Issue。
