# WinFile 产品官网

线上地址：<https://fakeruzi.github.io/macos_winfile/>

此分支 `codex/website` 独立维护官网，只包含网页、图片与部署工具，不包含 Swift 应用代码，也不依赖 `main` 中的文件。应用代码在 [main 分支](https://github.com/fakerUZI/macos_winfile/tree/main)。不要将这两个分支互相合并。

## 独立维护

建议单独克隆到另一个目录，避免在应用工作目录中切换分支：

```sh
git clone --single-branch --branch codex/website https://github.com/fakerUZI/macos_winfile.git winfile-website
cd winfile-website
```

也可以直接在 GitHub 切换到 `codex/website` 编辑文件。提交到本分支后，GitHub Actions 自动构建并部署 GitHub Pages。`main` 的应用改动不会发布网页。

## 本地预览

需要 Python 3.9+，无需 npm 或前端依赖：

```sh
python3 tools/build_website.py
python3 -m http.server 4173 --bind 127.0.0.1 --directory .site-build
```

打开 <http://127.0.0.1:4173/>。修改后重新构建并刷新。`.site-build/` 是临时产物，不提交。

## 修改哪些文件

- `index.html`：文案、导航、下载入口、FAQ 和功能介绍。
- `styles.css`：配色、布局与手机适配。
- `app.js`：可键盘操作的功能页签、截图放大和安装命令复制。
- `assets/`：网站独立保存的图标和真实界面截图；更新前检查隐私。
- `site.json`：页面展示的版本号 `version` 与最低 macOS 版本 `minimum_macos`。

发布新应用版本后，在本分支更新 `site.json` 中的展示版本。页面里的 `{{VERSION}}` 和 `{{MIN_MACOS}}` 在构建时替换。下载与更新记录链接始终指向 GitHub 最新稳定发行版，发布时请保留 `WinFile.zip` 通用资源名。

## 部署配置

Pages 使用 **GitHub Actions**，仅允许 `codex/website` 部署到 `github-pages` 环境。工作流为 `.github/workflows/pages.yml`，推送网页、配置、图片或构建工具的改动时触发。

[查看本分支部署记录](https://github.com/fakerUZI/macos_winfile/actions?query=branch%3Acodex%2Fwebsite)。需要重新部署时，可以对本分支已有的工作流运行选择 Re-run jobs；纯文档修改不触发部署。

构建检查图片、资源和锚点，只上传 `.site-build/` 的固定资源，不需要额外密钥、第三方字体或统计服务。

## 验收

检查桌面和手机布局、三个功能页签（方向键 / Home / End）、截图放大（Escape 关闭）、FAQ、安装命令复制及下载链接。关闭 JavaScript 时，三个功能介绍仍可阅读。页面尊重系统减少动态效果设置。
