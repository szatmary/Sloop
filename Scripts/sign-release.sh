#!/usr/bin/env bash
#
# Build, Developer ID sign, notarize and staple the macOS app — the sequence
# that produces something other people can run without a Gatekeeper fight.
#
#   Scripts/sign-release.sh                 # build, sign, notarize, staple
#   SKIP_NOTARIZE=1 Scripts/sign-release.sh # stop after signing
#
# Requires: a paid Apple Developer account, a "Developer ID Application"
# certificate in the login keychain, and (for notarization) a stored notarytool
# profile — see Docs/SIGNING.md.
#
# WHY THIS IS NOT JUST `codesign --sign "Developer ID Application"`:
#
# Sloop's key library needs the keychain-access-groups entitlement, which macOS
# treats as *restricted*: it is only granted by a provisioning profile embedded
# in the app bundle. Signing the entitlements plist directly with codesign
# produces an app that passes `codesign --verify` and then is killed by the
# kernel the instant it launches ("Code has restricted entitlements, but the
# validation of its code signature failed"). Worse, the plist contains
# $(AppIdentifierPrefix), an Xcode build variable that bare codesign does not
# expand, so the entitlement would name a literally nonexistent group.
#
# archive + exportArchive is what creates the Developer ID provisioning
# profile, embeds it, and expands the entitlements — so that is the path.
set -euo pipefail

TEAM_ID="${TEAM_ID:-KR5WZAG3UE}"
NOTARY_PROFILE="${NOTARY_PROFILE:-sloop-notary}"
SCHEME="Sloop_macOS"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Sloop.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/$SCHEME.app"

cd "$ROOT"
rm -rf "$BUILD"
mkdir -p "$BUILD"

if [ ! -d "Vendor/libssh2.xcframework" ]; then
  echo "error: Vendor/libssh2.xcframework is missing — run Scripts/build-libssh2.sh" >&2
  exit 1
fi

echo "==> Generating the Xcode project (SSH variant)"
xcodegen generate --spec project.ssh.yml >/dev/null

echo "==> Archiving"
xcodebuild -project Sloop.xcodeproj -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting a Developer ID signed app"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$EXPORT" -allowProvisioningUpdates

# The check that catches the failure mode described at the top: an app missing
# its embedded profile signs and verifies fine, then dies on launch.
if [ ! -f "$APP/Contents/embedded.provisionprofile" ]; then
  echo "error: no embedded.provisionprofile in the exported app — the restricted" >&2
  echo "       keychain-access-groups entitlement will not be granted and the app" >&2
  echo "       will be killed on launch. See Docs/SIGNING.md." >&2
  exit 1
fi

echo "==> Signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A3 keychain-access-groups || true

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "==> Skipping notarization (SKIP_NOTARIZE set). App: $APP"
  exit 0
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: no stored notarytool profile named '$NOTARY_PROFILE'.

Create one once with an app-specific password from appleid.apple.com:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your Apple ID>" --team-id "$TEAM_ID" --password "<app-specific password>"

Or re-run with SKIP_NOTARIZE=1 to stop after signing.
EOF
  exit 1
fi

echo "==> Notarizing (this waits on Apple's servers)"
ZIP="$BUILD/Sloop-macOS.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the distributed archive contains the stapled app; a ticket stapled
# after zipping is not in the zip.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP" || true

echo
echo "Done:"
echo "  app: $APP"
echo "  zip: $ZIP"
