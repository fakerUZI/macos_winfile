#!/bin/bash
# Install the latest verified LeafFiles release without Xcode or Homebrew.
# Legacy WinFile archive/app/executable names deliberately preserve existing installs.
set -euo pipefail

RELEASE_URL="https://github.com/fakerUZI/macos_winfile/releases/latest/download"
INSTALL_DIR="/Applications"
OPEN_APP=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) [ "$#" -ge 2 ] || { echo 'Missing directory after --dir' >&2; exit 2; }; INSTALL_DIR="$2"; shift 2 ;;
    --no-open) OPEN_APP=0; shift ;;
    --help|-h) echo 'Usage: bash install.sh [--dir "$HOME/Applications"] [--no-open]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "$(uname -s)" = Darwin ] || { echo 'LeafFiles requires macOS.' >&2; exit 1; }
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 13 ] || { echo 'LeafFiles requires macOS 13 or later.' >&2; exit 1; }
case "$(uname -m)" in arm64|x86_64) ;; *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;; esac
if pgrep -x WinFile >/dev/null 2>&1; then
  echo 'Please quit LeafFiles before installing, then run this command again.' >&2; exit 1
fi
mkdir -p "$INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || { echo 'Cannot write to the install directory. Try: --dir "$HOME/Applications"' >&2; exit 1; }
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
TARGET="$INSTALL_DIR/WinFile.app"
[ ! -L "$TARGET" ] || { echo 'Refusing to replace a symbolic-link application.' >&2; exit 1; }
[ ! -e "$TARGET" ] || [ -d "$TARGET" ] || { echo 'WinFile.app is not a directory.' >&2; exit 1; }
DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/winfile-download.XXXXXX")"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.WinFile-install.XXXXXX")"
BACKUP=""
INSTALL_STARTED=0
INSTALL_DONE=0
cleanup() {
  status=$?
  if [ "$INSTALL_DONE" = 0 ] && { [ "$INSTALL_STARTED" = 1 ] || { [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; }; }; then
    rm -rf "$TARGET"
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
  fi
  rm -rf "$DOWNLOAD_DIR" "$STAGING_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo 'Downloading the latest LeafFiles release…'
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 2 \
  "$RELEASE_URL/WinFile.zip" -o "$DOWNLOAD_DIR/WinFile.zip"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 2 \
  "$RELEASE_URL/WinFile.zip.sha256" -o "$DOWNLOAD_DIR/WinFile.zip.sha256"
EXPECTED="$(awk 'NR == 1 { print $1 }' "$DOWNLOAD_DIR/WinFile.zip.sha256")"
ACTUAL="$(shasum -a 256 "$DOWNLOAD_DIR/WinFile.zip" | awk '{ print $1 }')"
[[ "$EXPECTED" =~ ^[[:xdigit:]]{64}$ ]] && [ "$ACTUAL" = "$EXPECTED" ] || { echo 'SHA-256 verification failed; existing app was not changed.' >&2; exit 1; }
/usr/bin/ditto -x -k "$DOWNLOAD_DIR/WinFile.zip" "$STAGING_DIR/unpacked"
SOURCE="$STAGING_DIR/unpacked/WinFile.app"
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || { echo 'Release does not contain WinFile.app.' >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" = 'local.winfile.mac' ] || { echo 'Unexpected application identifier.' >&2; exit 1; }
# Copy without Finder/resource-fork attributes before checking the complete bundle.
/usr/bin/ditto --noextattr --norsrc "$SOURCE" "$STAGING_DIR/WinFile.app"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/WinFile.app"
if pgrep -x WinFile >/dev/null 2>&1; then echo 'LeafFiles started during download. Quit it and retry.' >&2; exit 1; fi
if [ -e "$TARGET" ]; then
  BACKUP_DIR="$INSTALL_DIR/.WinFile-backups"
  [ ! -L "$BACKUP_DIR" ] || { echo 'Backup directory must not be a symbolic link.' >&2; exit 1; }
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/WinFile-$(date +%Y%m%d-%H%M%S)-$$.app"
  mv "$TARGET" "$BACKUP"
fi
INSTALL_STARTED=1
mv "$STAGING_DIR/WinFile.app" "$TARGET"
/usr/bin/codesign --verify --deep --strict "$TARGET"
INSTALL_DONE=1
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
echo "Installed LeafFiles $VERSION: $TARGET"
[ -z "$BACKUP" ] || echo "Previous version saved: $BACKUP"
if [ "$OPEN_APP" = 1 ]; then /usr/bin/open "$TARGET"; fi
