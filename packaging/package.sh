#!/bin/bash
# Builds "Tiny reMarkable.app" (release) and a styled DMG installer.
# Usage: packaging/package.sh [version]   (default version 1.0.0)
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Display name (Finder/app), and internal names that Bundle.module depends on.
APP_NAME="Tiny reMarkable"
EXE="tinyreMarkable"
RES_BUNDLE="tinyreMarkable_tinyreMarkable.bundle"
VOL="Tiny reMarkable Installer"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$BIN/$APP_NAME.app"
ICON="$ROOT/packaging/AppIcon.icns"
[ -f "$ICON" ] || swift "$ROOT/packaging/make_icon.swift" "$ICON"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Bundle.module looks for the resource bundle at Bundle.main.bundleURL (the .app root).
cp -R "$BIN/$RES_BUNDLE" "$APP/$RES_BUNDLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.ffabbr.tinyreMarkable</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Building DMG"
WORK="$BIN/dmg-stage"
DMG_TMP="$BIN/$EXE-rw.dmg"
DMG_OUT="$BIN/$EXE-$VERSION.dmg"
MNT="/Volumes/$VOL"
rm -rf "$WORK" "$DMG_TMP" "$DMG_OUT"
mkdir -p "$WORK"
cp -R "$APP" "$WORK/$APP_NAME.app"
ln -s /Applications "$WORK/Applications"

hdiutil create -srcfolder "$WORK" -volname "$VOL" -fs HFS+ -format UDRW -ov "$DMG_TMP" >/dev/null
hdiutil attach "$DMG_TMP" -nobrowse -mountpoint "$MNT" >/dev/null

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 100, 1120, 460}
    set vo to icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 144
    set position of item "$APP_NAME.app" of container window to {145, 185}
    set position of item "Applications" of container window to {575, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
cp "$MNT/.DS_Store" "$ROOT/packaging/dmg_DS_Store" 2>/dev/null || true

# Robust detach: force, bounded retry (the volume is briefly busy after Finder closes).
for _ in $(seq 1 12); do
  if hdiutil detach "$MNT" -force >/dev/null 2>&1; then break; fi
  sleep 2
done

hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_OUT" >/dev/null
rm -f "$DMG_TMP"; rm -rf "$WORK"

echo "==> Done: $DMG_OUT"
hdiutil verify "$DMG_OUT" 2>&1 | tail -1
