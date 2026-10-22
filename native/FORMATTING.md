# Native code formatting

The Android/MTP module uses `native/.swift-format` (four spaces, 120 columns).
The Objective-C helper uses `native/MTPHelper/.clang-format` with clang-format 19.1.7.
Formatting tools are development-only and are not bundled with the app.

```bash
xcrun swift-format format --in-place --configuration native/.swift-format \
  native/WinFile/Android/*.swift native/WinFileTests/AndroidProbe.swift
clang-format --style=file -i native/MTPHelper/main.m
```

To check without editing:

```bash
xcrun swift-format lint --strict --configuration native/.swift-format \
  native/WinFile/Android/*.swift native/WinFileTests/AndroidProbe.swift
clang-format --dry-run --Werror --style=file native/MTPHelper/main.m
```

In shared files such as `BrowserModel.swift` and `NativeTestSuite.swift`, format
only the functions being changed to keep unrelated code out of the diff.
The MTP device probe lives in `WinFileTests/AndroidProbe.swift`; both native build
scripts include it explicitly alongside the other test helpers.
