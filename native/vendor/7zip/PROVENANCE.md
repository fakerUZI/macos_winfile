# 7-Zip console engine

Unmodified upstream 7zz 26.04 (2026-10-05), universal macOS arm64/x86_64.
Source: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz
Upstream package SHA-256: bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578
Upstream executable SHA-256: 36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577

7-Zip Copyright (C) 1999-2026 Igor Pavlov. Distributed under GNU LGPL 2.1 or later, BSD licenses and the unRAR restriction; see License.txt.
Full corresponding source: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-src.tar.xz
Project and source downloads: https://www.7-zip.org/
The helper is a separate executable; it is copied and re-signed by the app build, not linked into WinFile.
To replace or rebuild it, put the compatible universal 7zz at this path and update the checksum in native/build_native.sh and this file.
