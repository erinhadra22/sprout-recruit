#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
python3 create_project.py
plutil -lint Info.plist SproutCallPilot.xcodeproj/project.pbxproj
xcrun swiftc -frontend -parse Sources/*.swift
pilot_sdk="${SPROUT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
pilot_temp="$(mktemp -d /private/tmp/sprout-mobile-check.XXXXXX)"
trap 'rm -rf "$pilot_temp"' EXIT
xcrun swiftc -swift-version 5 -sdk "$pilot_sdk" -target arm64-apple-macosx13.0 \
  -module-cache-path "$pilot_temp/cache" Sources/PilotRecord.swift Tests/PilotRecordTests.swift -o "$pilot_temp/model-check"
"$pilot_temp/model-check"
xcrun swiftc -typecheck -swift-version 5 -sdk "$pilot_sdk" -target arm64-apple-macosx13.0 \
  -module-cache-path "$pilot_temp/cache" Sources/SessionKeychain.swift
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
echo "Local checks finished. These do not build the iPhone target, resolve the SDK, or prove a call/recording."
