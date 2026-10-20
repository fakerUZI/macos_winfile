# WinFile 产品网站

线上地址：<https://fakeruzi.github.io/macos_winfile/>

清新绿色的中文产品介绍页，使用 HTML / CSS / 原生 JavaScript。无需 npm、前端框架、第三方字体或统计服务。托管于本仓库的 GitHub Pages。

## 本地预览

在仓库根目录执行（需要 Python 3.9+）：

```sh
python3 tools/build_website.py
python3 -m http.server 4173 --bind 127.0.0.1 --directory .site-build
```

打开 <http://127.0.0.1:4173/>。修改后重新运行构建命令并刷新。构建产物 `.site-build/` 不提交。

## 修改内容

- `website/index.html`：文案、导航、下载入口、FAQ 与功能面板。
- `website/styles.css`：配色、布局与手机适配。
- `website/app.js`：可键盘操作的功能页签、截图放大与安装命令复制。
- `docs/screenshots/*.png`：复用 README 的真实界面截图。使用示例附件或公开目录，提交前检查隐私。
- `docs/icon/AppIcon-1024.png`：品牌图标。

`{{VERSION}}` 与 `{{MIN_MACOS}}` 在构建时从 `native/Info.plist` 自动替换。下载链接始终指向 GitHub 最新稳定发行版的 `WinFile.zip`，发布时请保留这个通用资源名。页面版本信息跟随 main 分支中的 Info.plist；请与正式发行版同步更新。

## 发布

Pages 发布源设置为 **GitHub Actions**。推送上述网页、截图、应用版本或构建工作流的改动到 main 后，`.github/workflows/pages.yml` 自动构建、检查本地资源和锚点、部署。也可以在 Actions 的 **Deploy product website** 手动运行。

只上传 `.site-build/`，不会公开整个仓库目录。构建脚本通过固定清单复制资源，不依赖 GitHub API，不需要额外密钥。GitHub 仓库必须保持可使用 Pages 的状态。

部署状态：<https://github.com/fakerUZI/macos_winfile/actions/workflows/pages.yml>

## 验收

检查桌面和手机布局、三个功能页签（含方向键 / Home / End）、截图放大（含 Escape 关闭）、FAQ、复制安装命令及下载入口。关闭 JavaScript 时三个功能介绍仍可阅读。页面尊重减少动态效果的系统设置。
