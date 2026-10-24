# LeafFiles 安装目录名称统一（2026-10-24）

> 本文记录该轮验证时的状态；最终 2.0.1 构建、配色与发布结果以[发行验收记录](2026-10-24-release-2.0.1.md)为准。

本地 `/Applications/WinFile.app` 已原地改名为 `/Applications/LeafFiles.app`，更新 LaunchServices 并确认新路径可正常启动、三个页签保留。访达应用程序目录的辅助功能树显示 LeafFiles.app，原路径不存在。项目根目录的构建副本也统一为 LeafFiles.app。

构建脚本输出 LeafFiles.app，内部可执行文件仍为 WinFile，应用标识、设置、curl URL、下载资产名称及更新签名不变。打包脚本将归档内应用名称规范为 LeafFiles.app；现有 WinFile.zip 下载地址继续使用。

安装脚本接受旧 WinFile.app 与新 LeafFiles.app 归档。安装成功后旧应用移入隐藏备份目录；同时存在两种名称时合并为一个 LeafFiles.app。替换失败恢复原名称和原内容，拒绝符号链接与不同标识的应用。

验证：旧名称归档和新名称归档分别通过 11 项安装集成场景（共 22 项），包含首次安装、备份、摘要错误、运行状态、签名错误、替换后回滚、旧名迁移失败回滚、成功迁移、双目录合并、旧名符号链接拒绝、双目录合并失败恢复。全部在临时目录运行，未下载安装远程旧版本覆盖本机。

`bash -n`、Python 编译检查、git diff --check、已安装和重命名构建副本的签名校验通过。归档根目录确认只有 LeafFiles.app。本轮未修改 Swift 业务源码，没有重新编译应用。

Sparkle 2.10.0 的安装器支持在名称不匹配时按 bundle identifier 查找更新，并默认保留宿主安装路径；已迁移到 LeafFiles.app 的本地应用可沿用原更新源。旧版用户仍叫 WinFile.app 时，可通过新安装脚本迁移；未声称一次 Sparkle 更新会自动更改所有旧安装路径。

依据：[Sparkle 2.10.0 SUInstaller 源码](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/SUInstaller.m)。本次没有对线上版本执行实际升级，也未签名、上传或发布新的更新包。

代码和安装脚本已在本地修改，尚未提交或推送，线上 curl 脚本将在后续推送后生效。
