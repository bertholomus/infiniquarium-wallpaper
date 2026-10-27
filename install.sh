#!/bin/bash
# Infiniquarium live wallpaper: builds the small menu-bar app with Apple's compiler,
# installs it to ~/Applications and starts it. Run it again any time to update.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Infiniquarium.app"
ID="com.infiniquarium.wallpaper"

echo "Infiniquarium wallpaper"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's command line tools aren't installed. Run:  xcode-select --install"
  echo "then run this installer again."
  exit 1
fi
for f in Infiniquarium.swift infiniquarium.html; do
  [ -f "$HERE/$f" ] || { echo "Missing $f next to this script."; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE/Infiniquarium.swift" "$WORK/main.swift"

echo "• Compiling (takes a little while the first time)…"
if ! xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos11.0" \
  -framework AppKit -framework WebKit -framework Network "$WORK/main.swift" -o "$WORK/Infiniquarium" 2> "$WORK/build.txt"; then
  cat "$WORK/build.txt"
  cp "$WORK/build.txt" "$HERE/install-errors.txt" 2>/dev/null || true
  echo
  echo "The build failed (details in install-errors.txt). The tank that's running was left as it was."
  exit 1
fi
rm -f "$HERE/install-errors.txt"

if pgrep -x Infiniquarium >/dev/null 2>&1; then
  echo "• Saving and stopping the running tank…"
  pkill -TERM -x Infiniquarium || true
  for _ in $(seq 1 40); do pgrep -x Infiniquarium >/dev/null 2>&1 || break; sleep 0.2; done
fi

echo "• Installing to $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/Infiniquarium" "$APP/Contents/MacOS/Infiniquarium"
cp "$HERE/infiniquarium.html" "$APP/Contents/Resources/infiniquarium.html"
[ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Infiniquarium</string>
  <key>CFBundleDisplayName</key><string>Infiniquarium</string>
  <key>CFBundleExecutable</key><string>Infiniquarium</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "• Starting…"
rm -f "$HERE/wallpaper.log"
open "$APP" --args --log "$HERE/wallpaper.log"
echo
echo "Done. Infiniquarium is now your wallpaper."
echo "To feed, trim or explore it, click the fish in the menu bar and choose Open in Browser."
