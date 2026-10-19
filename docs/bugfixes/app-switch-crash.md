# 切换应用时的鼠标坐标崩溃

## 用户报告

WinFile 1.1.0 (2)，Intel Mac，macOS 26.1。双击文件打开其他应用或切换应用后退出。
两份报告的主线程均为 `EXC_BAD_INSTRUCTION / SIGILL`，栈顶为
`closure #3 in EmptyAreaContextMenu.InstallerView.attachIfNeeded() + 4505`。

## 已确认的原因

本地保留的发布程序 x86_64 UUID 为 `702713B4-0557-3C64-919E-D183C6B15520`，
与用户报告一致。报告中的 image offset `0x72dc9` 对应 `ud2`；跳到该地址的分支是
左键诊断闭包里 `Int(event.locationInWindow.x)` 的非有限数检查。
报告寄存器中的坐标绝对值位模式 `0x7fffffffe0000000` 是 NaN，符合该分支条件。

问题由诊断日志的浮点数到整数转换触发。失效坐标不应进入命中测试、磁贴激活或整数转换。
同一闭包还有其他布局坐标到整数的转换，也需要消除相同风险。

此外，左键监听闭包强引用窗口；安装器换窗口时只移除了旧右键监听器。
这会使旧的左键监听器与窗口留存，因此同步修复监听器生命周期。

## 修复

- 左右键处理先验证事件所属窗口、坐标有限性、转换后的坐标及内容区范围。无效事件原样交回 AppKit。
- 诊断数值使用不会触发整数转换陷阱的字符串格式化；磁贴查找拒绝非有限坐标。
- 左键监听器弱引用安装器，窗口变更、视图移除和 SwiftUI 拆除时同时卸载左右键监听器。
- 保留正常单击透传、图标双击激活一次以及右键菜单行为。

## 回归验证

`NativeTestSuite.testMouseEventSafety()` 使用真实 `NSEvent.mouseEvent` 注入
NaN、正负无穷、超大有限值、`CGFloat(Int.max)` 和窗口外坐标，检查安全透传与不误激活。
同时验证正常单击/双击、视图拆卸、重复安装及跨窗口重新挂载。

```bash
./native/run_native_tests.sh --quick --cli-only --skip-device-tests
```

完整应用另需运行 arm64 与 x86_64 的 `--run-tests --skip-device-tests`，并验收应用切换、
双击打开外部应用、列表/图标视图切换及右键菜单。
Rosetta 的 x86_64 结果可验证 Intel 指令路径，但不等同于在用户的 Intel Mac / macOS 26.1 环境实测。

本次验证结果：命令行 736 项通过；英文应用包 arm64、x86_64（Rosetta）各 741 项通过。
真实界面验证了双击文件在 TextEdit 中打开、返回 WinFile、重复切换应用、
图标/详细信息布局切换，以及文件夹和空白区域右键菜单。
