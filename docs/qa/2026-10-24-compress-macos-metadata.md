# 压缩时过滤 macOS 杂项

范围：v2.0.2 发布后的 main 工作区。本记录对应版本号仍为 2.0.2 (15) 时的提交前功能验收；随后纳入 2.0.3，正式发行验证见 [2.0.3 发行验收](2026-10-24-release-2.0.3.md)。仅调整创建 ZIP 的内容筛选，不改动已有压缩包或源文件。

## 规则

- 排除根目录和嵌套目录中的 `.DS_Store`、`._*`、`__MACOSX` 目录及其内容；同一父目录与跨目录合并压缩共用规则。
- 保留 `.git`、`.env`、`.gitignore`、`.config`、`.localized` 等其他隐藏项、空目录和符号链接本身。
- 相似名称如 `.DS_Store.backup`、`report._draft.txt` 和 `__MACOSX_notes` 不会被误过滤。
- 直接选中杂项会先过滤；若所选项目全部为杂项，显示中英文提示，不生成空包。
- 使用 ZIP 的名称排除列表，未增加全面隐藏文件过滤或移除普通文件属性的参数。输入文件名置于 `--` 后，支持横线开头的名称。

## 验证

`native/run_native_tests.sh --quick --cli-only --skip-device-tests`：**1,270 项通过，0 失败**，其中新增 11 项检查。

新增测试实际创建 ZIP 并直接核对原始包内条目，避免解压阶段自动清理 `__MACOSX` 掩盖打包问题；随后解压并比较保留文件的字节。覆盖根层和多层杂项、正常隐藏文件与相似名称、空隐藏目录、符号链接、直接多选、跨目录同名隐藏文件、全杂项提示、无残缺产物，以及源文件内容不变。

测试不操作真实安卓设备，不清理用户文件。日志：本机 `/tmp/leaffiles-compress-metadata-tests.log`。

## 本机构建与安装

- `native/build_native.sh --in-place` 正式优化的 arm64 / x86_64 通用构建通过，完整应用签名校验正常。本轮没有重复运行应用包内或 Intel/Rosetta 全量测试。
- 已更新 `/Applications/LeafFiles.app`，安装后二进制 SHA-256 与验证构建一致；中英资源均包含全杂项选择提示。
- 正常退出后完成替换并重启，保留原有「压缩包」分类页签、图标视图和收藏。旧应用保留在 `/Applications/.WinFile-backups/`。
- 中英资源格式及 `git diff --check` 通过。构建日志：本机 `/tmp/leaffiles-compress-metadata-build.log`。
