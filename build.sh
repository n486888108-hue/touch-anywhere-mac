#!/bin/bash
# TouchAnywhere - build and install
#   bash build.sh              build only; the app ends up in ~/Library/Caches/TouchAnywhere-build/
#   bash build.sh --install    build, copy to ~/Applications/TouchAnywhere.app and launch it
# Needs only the Swift compiler that ships with the Xcode Command Line Tools (xcode-select --install). No Xcode, no network.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/Library/Caches/TouchAnywhere-build"
APP="$OUT/TouchAnywhere.app"
DEST="$HOME/Applications/TouchAnywhere.app"
ID="io.github.touchanywhere"

mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$D/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  "$D/Strings.swift" "$D/TouchEngine.swift" "$D/HitTest.swift" "$D/App.swift" -o "$APP/Contents/MacOS/TouchAnywhere"
# App icon: the app draws its own icon sizes, then they are packed into an .icns (falls back to the default icon if that fails)
rm -rf "$OUT/AppIcon.iconset"
"$APP/Contents/MacOS/TouchAnywhere" --make-icon "$OUT/AppIcon.iconset" \
  && iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || echo "(icon not generated, using the default icon)"
# Ad-hoc signature whose designated requirement is only the bundle identifier. Without this, every rebuild changes the
# code hash and macOS silently drops the Accessibility permission you granted (the switch looks on, but the app is untrusted).
codesign --force --sign - -r="designated => identifier \"$ID\"" "$APP" >/dev/null 2>&1
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
  if pgrep -x TouchAnywhere >/dev/null; then
    osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do pgrep -x TouchAnywhere >/dev/null || break; sleep 1; done
    if pgrep -x TouchAnywhere >/dev/null; then echo "TouchAnywhere is still running, not replaced. Quit it from its menu-bar icon and re-run."; exit 1; fi
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and started: $DEST (look for the hand icon in the menu bar)"
  echo "Next: System Settings > Privacy & Security > Accessibility > allow TouchAnywhere."
fi
