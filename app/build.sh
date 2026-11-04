#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="${SPROUT_OUTPUT:-$PWD/Sprout Recruit.app}"
ARCH="${SPROUT_ARCH:-$(uname -m)}"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { print -u2 'Unsupported architecture'; exit 1; }
# Local pilot builds select a persistent certificate by its public SHA-1 hash.
# Keep this explicit: no private key, implicit identity lookup or trust changes.
LOCAL_SIGNING_IDENTITY="${SPROUT_LOCAL_SIGNING_IDENTITY:-}"
LOCAL_SIGNING_FILE="$PWD/.local-signing-identity"
# Per-Mac public fingerprint only. Explicit environment selections take precedence.
# The file is exactly 40 hex bytes without a newline; never source or evaluate it.
if [[ -z "$LOCAL_SIGNING_IDENTITY" && -z "${SPROUT_SIGNING_IDENTITY:-}" && ( -e "$LOCAL_SIGNING_FILE" || -L "$LOCAL_SIGNING_FILE" ) ]]; then
  [[ -f "$LOCAL_SIGNING_FILE" && ! -L "$LOCAL_SIGNING_FILE" && -r "$LOCAL_SIGNING_FILE" ]] || { print -u2 'Local signing identity must be a readable regular file'; exit 1; }
  [[ "$(/usr/bin/stat -f %z "$LOCAL_SIGNING_FILE")" == 40 ]] || { print -u2 'Local signing identity file must contain exactly 40 hexadecimal bytes without a newline'; exit 1; }
  LOCAL_SIGNING_IDENTITY="$(< "$LOCAL_SIGNING_FILE")"
  [[ ${#LOCAL_SIGNING_IDENTITY} -eq 40 && "$LOCAL_SIGNING_IDENTITY" != *[^[:xdigit:]]* ]] || { print -u2 'Local signing identity file must contain only a 40-character certificate SHA-1'; exit 1; }
fi
if [[ -n "$LOCAL_SIGNING_IDENTITY" ]]; then
  [[ -z "${SPROUT_SIGNING_IDENTITY:-}" ]] || { print -u2 'Choose either local or distribution signing, not both'; exit 1; }
  [[ ${#LOCAL_SIGNING_IDENTITY} -eq 40 && "$LOCAL_SIGNING_IDENTITY" != *[^[:xdigit:]]* ]] || { print -u2 'SPROUT_LOCAL_SIGNING_IDENTITY must be the certificate SHA-1: exactly 40 hexadecimal characters'; exit 1; }
fi
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
<key>CFBundleShortVersionString</key><string>0.10.0</string>
<key>CFBundleVersion</key><string>25</string>
<key>SproutRecoveryCLIVersion</key><integer>1</integer>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSDocumentsFolderUsageDescription</key><string>Sprout opens your existing recruiting workspace and keeps verified local recovery snapshots.</string>
<key>NSAppleEventsUsageDescription</key><string>Sprout sends the exact texts you approve through your existing Messages account in the background.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ -n "$LOCAL_SIGNING_IDENTITY" ]]; then
  # Self-signed local identities do not use Apple's timestamp authority.
  # Retain the pilot's existing runtime behavior; this is not notarized distribution.
  codesign --force --timestamp=none --sign "$LOCAL_SIGNING_IDENTITY" "$APP"
elif [[ -n "${SPROUT_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --entitlements Assets/SproutRecruit.entitlements --timestamp --sign "$SPROUT_SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
print "Built: $APP"
