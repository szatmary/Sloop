# Signing & notarization

Three tiers, from what runs today to what ships:

| Tier | What it is | Gatekeeper on download | Needs |
| --- | --- | --- | --- |
| **Ad-hoc** (today) | `codesign --sign -` in CI | Blocked — user must clear quarantine / right-click Open | nothing |
| **Developer ID + notarization** | Real signature + Apple's notary ticket | **Opens cleanly** | paid Apple Developer account |
| **App Store** | Distribution signing + review | n/a (Store install) | account + App Store Connect |

**There is no "self-notarization."** Notarization runs on Apple's servers and
rejects ad-hoc / self-signed binaries. It requires a paid **Apple Developer
Program** membership ($99/yr) and a **Developer ID Application** certificate.
Nothing local reproduces it.

## What to do once you have an Apple Developer account

1. In the Apple Developer portal, create a **Developer ID Application**
   certificate. Export it (with its private key) from Keychain Access as a
   `.p12` with a password.
2. Create an **app-specific password** for your Apple ID (or an App Store
   Connect API key) for `notarytool`.
3. Add these as **GitHub Actions repo secrets**:
   - `DEVELOPER_ID_P12_BASE64` — `base64 -i cert.p12` output
   - `DEVELOPER_ID_P12_PASSWORD` — the `.p12` password
   - `AC_APPLE_ID` — your Apple ID email
   - `AC_TEAM_ID` — your 10-char Team ID
   - `AC_PASSWORD` — the app-specific password
4. Ask me to enable the notarized-release job (scaffolded below) — it's gated on
   the secrets being present, so it stays dormant until then.

## The CI steps (drop-in for the mac-release job)

Replace the ad-hoc `codesign` in Package with a real sign + notarize:

```sh
# import the Developer ID cert into a temporary keychain
echo "$DEVELOPER_ID_P12_BASE64" | base64 -d > cert.p12
security create-keychain -p "" build.keychain
security import cert.p12 -k build.keychain -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign
security list-keychains -s build.keychain
security set-key-partition-list -S apple-tool:,apple: -s -k "" build.keychain

# sign with hardened runtime + secure timestamp (required for notarization)
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application" build/pkg/Sloop.app

# zip, submit to Apple, wait, then staple the ticket onto the app
ditto -c -k --keepParent build/pkg/Sloop.app Sloop-macOS.zip
xcrun notarytool submit Sloop-macOS.zip \
  --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD" --wait
xcrun stapler staple build/pkg/Sloop.app
ditto -c -k --keepParent build/pkg/Sloop.app Sloop-macOS.zip   # re-zip stapled app
```

A notarized, stapled build opens on any Mac with no quarantine dance.

## iOS

iOS has no ad-hoc-download path at all — it needs a Developer account to run on
a device (development provisioning) and for TestFlight/App Store. Same account
unlocks both platforms.
