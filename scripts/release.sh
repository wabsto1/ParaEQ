#!/bin/bash
# Build, sign (Developer ID + hardened runtime), notarize, staple, and zip
# ParaEQ for distribution.
#
# Local usage (after one-time setup below):
#   scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
#
# One-time local setup:
#   xcrun notarytool store-credentials paraeq-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# CI usage: set NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID env vars
# (App Store Connect API key) instead of the keychain profile.
set -euo pipefail

IDENTITY="${1:-${MACOS_SIGNING_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
    echo "error: pass the Developer ID identity as \$1 or MACOS_SIGNING_IDENTITY" >&2
    exit 1
fi

APP=".build/ParaEQ.app"
ZIP=".build/ParaEQ.zip"

echo "==> Building"
swift build -c release --product ParaEQ
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ParaEQ "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

echo "==> Signing (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$ZIP" --wait \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID"
else
    xcrun notarytool submit "$ZIP" --wait --keychain-profile paraeq-notary
fi

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release artifact: $ZIP"
