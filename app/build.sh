#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="${SPROUT_OUTPUT:-$PWD/Sprout Recruit.app}"
ARCH="${SPROUT_ARCH:-$(uname -m)}"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { print -u2 'Unsupported architecture'; exit 1; }
# This workstation's default SDK is newer than its compiler. CI may override it.
if [[ -n "${SPROUT_SDK:-}" ]]; then
  SDK="$SPROUT_SDK"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "$SDK" ]] || { print -u2 'Selected macOS SDK is unavailable'; exit 1; }
CACHE="${TMPDIR:-/tmp}/sprout-swift-module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Web" "$CACHE"
swiftc -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx13.0" -O -module-cache-path "$CACHE" Sources/*.swift -o "$APP/Contents/MacOS/SproutRecruit" -framework Cocoa -framework WebKit -framework Security -framework PDFKit -lsqlite3
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cp Web/* "$APP/Contents/Resources/Web/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SproutRecruit</string>
<key>CFBundleIdentifier</key><string>com.sprout.recruit.local</string>
<key>CFBundleName</key><string>Sprout Recruit</string>
<key>CFBundleDisplayName</key><string>Sprout Recruit</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.8</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ -n "${SPROUT_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SPROUT_SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
print "Built: $APP"
