# LeafFiles 产品官网

[访问官网](https://fakeruzi.github.io/macos_winfile/) · [终端安装](https://fakeruzi.github.io/macos_winfile/#quick-install) · [应用源码](https://github.com/fakerUZI/macos_winfile/tree/main)

LeafFiles（原 WinFile）是免费开源的原生 macOS 文件管理器，提供空间清理、微信附件整理、MTP 安卓文件管理、多格式解压、多页签与个人收藏。当前介绍正式版 v2.0.3，重点呈现 ZIP 自动过滤 macOS 杂项、其他隐藏文件保留和跨目录合并压缩规则；继续介绍包内默认应用打开、空间清理、微信附件与安卓文件管理。

截至 2026 年 10 月 25 日，本轮回归与本机使用验证中暂未发现明显 Bug。后续聚焦文件管理，以界面与交互优化、性能改善和 Bug 修复为主，不扩展无关功能。中英文官网均注明本轮源码已提交滚动、悬停和提示栏修复，待后续安装包更新；终端安装仍提供当前正式版。

中文与英文页面均保留清新绿色视觉、首页顶部一键安装命令和右上角语言切换。首页界面优化截图使用隔离示例文件。压缩包截图来自 2.0.2 同源功能构建的隔离副本，展示默认应用打开按钮和内置文本预览，仅含生成的文本、Markdown、图片、视频及大小边界样例；空间清理截图保留 v1.3.0 标注，MTP 截图来自真实设备的生成样例，不含私人文件内容。预览大小、算法与设备限制见页面说明。

官网安装入口统一使用终端命令，不再提供 ZIP 直链。原一键安装命令、GitHub 地址与自动更新渠道保持不变，已有收藏与设置继续沿用。从 v2.0.1 起，安装目录为 LeafFiles.app，curl 脚本备份并迁移旧目录；应用内更新可能保留原目录名。部分历史截图仍使用 WinFile 名称。

```bash
curl -fsSL https://raw.githubusercontent.com/fakerUZI/macos_winfile/main/install.sh | /bin/bash
```
