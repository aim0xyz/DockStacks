#!/bin/zsh
# Builds a Developer ID signed and notarized build/DockStacks.zip for a GitHub release.
# Needs a "Developer ID Application" certificate and a notarytool keychain profile, made once with
# `xcrun notarytool store-credentials notary`; another profile name goes in DOCKSTACKS_NOTARY_PROFILE.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/DockStacks.app"
ZIP="$ROOT/build/DockStacks.zip"
PROFILE="${DOCKSTACKS_NOTARY_PROFILE:-notary}"
IDENTITY="${DOCKSTACKS_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')}"
[[ -z "$IDENTITY" ]] && { echo "No Developer ID Application certificate found" >&2; exit 1; }

DOCKSTACKS_SIGN_IDENTITY=- "$ROOT/scripts/build.sh"

# Notarization wants the hardened runtime and a secure timestamp on every executable, inside out.
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Resources/StackStub.app"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# Zip again, so the download carries the stapled ticket and opens without a network check.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Notarized $ZIP"
