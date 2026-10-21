#!/bin/bash
# Build & install Remote Monitor Control.
#   ./build.sh              build, install to /Applications, link `monitorctl`, export iPhone shortcuts, launch
#   ./build.sh --no-install build only (app ends up in ./dist)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="Remote Monitor Control"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

step "Checking tools"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ Full Xcode is required (App Intents need it). Install Xcode, then run:"
  echo "   sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
xcodebuild -version | head -1
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew…"
    brew install xcodegen
  else
    echo "❌ XcodeGen not found and Homebrew isn't available. Install from https://github.com/yonaskolb/XcodeGen"
    exit 1
  fi
fi

step "Generating Xcode project"
xcodegen generate --spec project.yml --quiet

step "Building (Release)"
# Build outside Documents: iCloud/file-provider folders add Finder metadata that makes codesign fail.
DERIVED="${HOME}/Library/Caches/RemoteMonitorControl/DerivedData"
xcodebuild \
  -project RemoteMonitorControl.xcodeproj \
  -scheme RemoteMonitorControl \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- \
  -quiet build

BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
mkdir -p dist
rm -rf "dist/$APP_NAME.app"
ditto "$BUILT" "dist/$APP_NAME.app"
echo "✅ Built dist/$APP_NAME.app"

[[ $INSTALL == 0 ]] && exit 0

step "Installing to /Applications"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
DEST="/Applications/$APP_NAME.app"
if ! { rm -rf "$DEST" 2>/dev/null && ditto "dist/$APP_NAME.app" "$DEST"; }; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/$APP_NAME.app"
  rm -rf "$DEST"
  ditto "dist/$APP_NAME.app" "$DEST"
fi
echo "Installed $DEST"
# Make Launch Services / Shortcuts pick up the App Intents right away
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

step "Linking the monitorctl command"
CLI="$DEST/Contents/MacOS/monitorctl"
LINKED=""
for dir in "$HOME/.homebrew/bin" /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$dir" && -w "$dir" ]]; then
    ln -sf "$CLI" "$dir/monitorctl"
    LINKED="$dir/monitorctl"
    break
  fi
done
[[ -n "$LINKED" ]] && echo "monitorctl → $LINKED" || echo "(add $CLI to your PATH to use monitorctl)"

step "Launching"
open "$DEST"
sleep 2

step "Monitors found"
"$CLI" list || true

step "Exporting iPhone shortcuts → $ROOT/Shortcuts"
"$CLI" export-shortcuts "$ROOT/Shortcuts" || echo "(you can re-run this later from the app: Export iPhone Shortcuts…)"

echo
echo "🎉 Done. Look for the display icon in the menu bar."
echo "   Shortcuts app → search “Monitor” for: Turn Monitor Off / On, Toggle, Switch Monitor Input…"
