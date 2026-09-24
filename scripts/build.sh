#!/bin/zsh
# Builds Headroom into ./build.
#   ./scripts/build.sh            build only
#   ./scripts/build.sh --install  also copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null; then
  echo "Xcode is required (install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Release \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Release/Headroom.app"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Headroom 2>/dev/null || true
  rm -rf /Applications/Headroom.app
  ditto "$APP" /Applications/Headroom.app
  open /Applications/Headroom.app
  echo "Installed to /Applications/Headroom.app and launched"
fi
