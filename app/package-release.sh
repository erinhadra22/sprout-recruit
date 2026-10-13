#!/bin/zsh
# Explicit preview mode is for local QA only. Release requires Developer ID + notarization.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-release}"
[[ "$MODE" == release || "$MODE" == --preview ]] || { print -u2 'Usage: package-release.sh [--preview]'; exit 1; }
if [[ "$MODE" == release ]]; then
  [[ "${SPROUT_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || { print -u2 'Release blocked: set SPROUT_SIGNING_IDENTITY to your Developer ID Application certificate.'; exit 1; }
  [[ -n "${SPROUT_NOTARY_PROFILE:-}" ]] || { print -u2 'Release blocked: set SPROUT_NOTARY_PROFILE to an existing notarytool Keychain profile.'; exit 1; }
fi
OUT="${SPROUT_RELEASE_DIR:-$PWD/dist}"
mkdir -p "$OUT"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sprout-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Sprout Recruit.app"
SPROUT_OUTPUT="$APP" zsh build.sh
if find "$APP" -type f \( -name '*.sqlite*' -o -name '*.csv' -o -name '.env*' -o -name '*.p12' -o -name '*.key' \) | read -r _; then
  print -u2 'Release blocked: unexpected data or credential material in bundle.'; exit 1
fi
NAME="Sprout-Recruit-0.4.8-${SPROUT_ARCH:-$(uname -m)}"
[[ "$MODE" == --preview ]] && NAME="$NAME-LOCAL-PREVIEW-NOT-NOTARIZED"
ZIP="$OUT/$NAME.zip"
[[ ! -e "$ZIP" ]] || { print -u2 "Output already exists: $ZIP"; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ "$MODE" == release ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$SPROUT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
shasum -a 256 "$ZIP" > "$ZIP.sha256"
print "Package: $ZIP"
