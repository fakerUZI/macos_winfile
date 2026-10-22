# MTP runtime

WinFile uses libmtp 1.1.23 and libusb 1.0.30 through its own Objective-C helper.
Both dependencies are dynamically linked, compiled for arm64 and x86_64, and bundled
in `Contents/Frameworks`; no package manager or USB debugging is required at runtime.

Sources, pinned SHA-256 checksums and reproducible build commands are in
`native/prepare_mtp.sh` and `native/build_mtp_helper.sh`.

- libmtp: https://github.com/libmtp/libmtp/releases/tag/v1.1.23
- libusb: https://github.com/libusb/libusb/releases/tag/v1.0.30

The upstream COPYING files are included with distributed apps. Linux-generated
headers are removed before configure regenerates them for macOS.
`no-usb-reset.patch` is a WinFile modification dated 2026-10-22: closing a file
session releases its MTP interface without forcibly resetting the entire USB
device. The patch and build scripts are included here and in distributed apps.
The dynamically linked libraries can be replaced by compatible rebuilt libraries;
local unsigned builds use ad-hoc signatures. Re-sign the helper and application
after replacing a library if macOS signature validation requires it.
