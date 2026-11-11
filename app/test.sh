#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
# PDFKit initializes AppKit; direct bundled CLI registration can abort before NSApplication startup.
# Test the identical compiled executable outside the bundle without omitting PDF coverage.
TEST_DIR="$(mktemp -d /tmp/sprout-native-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "${SPROUT_TEST_APP:-$PWD/Sprout Recruit.app}/Contents/MacOS/SproutRecruit" "$TEST_DIR/SproutRecruit"
"$TEST_DIR/SproutRecruit" --self-test
