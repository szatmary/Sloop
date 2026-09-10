# Signing & notarization

**Use `Scripts/sign-release.sh`.** It archives, exports a Developer ID signed
app, notarizes and staples. `SKIP_NOTARIZE=1` stops after signing.

Verified on 2026-08-17: the exported app is signed by
`Developer ID Application: Matthew Szatmary (KR5WZAG3UE)`, carries both
keychain-access-groups with the team prefix expanded, and the key library works
under that signature (`sloop list-keys` returned the real library). Notarization
itself is untested — it needs an app-specific password, see below.

## Do not sign the app with plain `codesign`

The obvious recipe is wrong, in a way that passes every local check and fails
only on a user's machine:

```sh
# BROKEN — do not use
codesign --force --deep --options runtime --timestamp \
  --entitlements App/Sloop/Sloop.entitlements \
  --sign "Developer ID Application" Sloop.app
```

Two independent problems:

1. **`keychain-access-groups` is a restricted entitlement.** macOS grants it
   only via a **provisioning profile embedded in the bundle**
   (`Contents/embedded.provisionprofile`). Signed without one, the app passes
   `codesign --verify --strict` and is then killed by the kernel the moment it
   launches — `Killed: 9`, with `Code has restricted entitlements, but the
   validation of its code signature failed` in the system log. Nothing in the
   signing or notarization pipeline warns you.
2. **`$(AppIdentifierPrefix)` is an Xcode build variable.** `codesign` does not
   expand it, so the entitlement ends up naming the literal group
   `$(AppIdentifierPrefix)org.szatmary.sloop.shared`, which exists nowhere.

`xcodebuild archive` + `-exportArchive` fixes both: it creates and embeds the
Developer ID provisioning profile, expands the entitlements, and adds the
`com.apple.application-identifier` entitlement that authorizes the restricted
one. That is what the script does, and it verifies the embedded profile is
present before going on.

## Tiers

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

### Running the ad-hoc `nightly` build

The `nightly` GitHub release is ad-hoc signed and not notarized, so Gatekeeper
blocks it on first launch. Right-click the app → **Open** → **Open**; if macOS
calls it *"damaged"*, clear the quarantine flag first:

```sh
xattr -cr /path/to/Sloop.app && open /path/to/Sloop.app
```

"Damaged" is Gatekeeper on an unnotarized download, not a real problem — it
goes away with Developer ID signing and notarization. Note that key auth does
not work at all in an ad-hoc build; see [`KEYS.md`](KEYS.md).

## Building locally, once entitlements exist

The app targets carry `CODE_SIGN_ENTITLEMENTS`
([`App/Sloop/Sloop.entitlements`](../App/Sloop/Sloop.entitlements), for the
shared keychain-access-group), so a bare

```sh
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS build
```

**fails** with *"requires a provisioning profile"* — there is no team selected
to sign the entitlement with. Three ways around it, depending on what you are
doing:

- **Interactive development** — open `Sloop.xcodeproj` and pick your team in
  the target's Signing & Capabilities tab once. Subsequent Xcode and
  `xcodebuild` invocations reuse it.
- **Scripted builds that need to run and use the app** — pass a team and let
  Xcode provision automatically:
  ```sh
  xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team> CODE_SIGN_STYLE=Automatic build
  ```
- **Test-only builds that never touch the shared keychain** — skip signing:
  ```sh
  xcodebuild test -project Sloop.xcodeproj -scheme Sloop_macOS \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  ```
  Key-library keychain calls then fail at runtime with a descriptive error,
  which is expected.

## What's already in place

The account exists and the certificates are on this Mac:

- `Developer ID Application: Matthew Szatmary (KR5WZAG3UE)` — distribution
- `Apple Development: Matthew Szatmary (NS9VS3BS4A)` — device builds

So local Developer ID signing works today via `Scripts/sign-release.sh`. What
remains before a release anyone else can run:

1. **A notarytool credential.** Create an app-specific password at
   appleid.apple.com, then store it once:
   ```sh
   xcrun notarytool store-credentials "sloop-notary" \
     --apple-id "<your Apple ID>" --team-id "KR5WZAG3UE" --password "<app-specific password>"
   ```
   The script looks for the profile named `sloop-notary` and explains this if
   it is missing.
2. **A decision about CI.** The steps below still describe the CI path, which
   is harder than the local one: `-allowProvisioningUpdates` needs an
   authenticated Xcode, so a runner cannot create the Developer ID profile on
   the fly. Either export the profile and add it as a secret alongside the
   `.p12`, or keep cutting releases from this Mac with the script.

## For CI, once you want it there

1. In the Apple Developer portal, export the **Developer ID Application**
   certificate (with its private key) from Keychain Access as a `.p12` with a
   password, and download the matching **Developer ID provisioning profile**
   for `org.szatmary.sloop` with Keychain Sharing enabled.
2. Create an **app-specific password** for your Apple ID (or an App Store
   Connect API key) for `notarytool`.
3. Add these as **GitHub Actions repo secrets**:
   - `DEVELOPER_ID_P12_BASE64` — `base64 -i cert.p12` output
   - `DEVELOPER_ID_P12_PASSWORD` — the `.p12` password
   - `DEVELOPER_ID_PROFILE_BASE64` — `base64 -i sloop.provisionprofile` output
   - `AC_APPLE_ID` — your Apple ID email
   - `AC_TEAM_ID` — your 10-char Team ID
   - `AC_PASSWORD` — the app-specific password
4. Ask me to enable the notarized-release job (scaffolded below) — it's gated on
   the secrets being present, so it stays dormant until then.

## The CI steps (drop-in for the mac-release job)

Replace the ad-hoc `codesign` in Package with a real sign + notarize:

```sh
# import the Developer ID cert AND the Developer ID provisioning profile.
# The profile is not optional: keychain-access-groups is a restricted
# entitlement and only an embedded profile grants it (see the top of this
# file for what happens without one).
echo "$DEVELOPER_ID_P12_BASE64" | base64 -d > cert.p12
security create-keychain -p "" build.keychain
security import cert.p12 -k build.keychain -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign
security list-keychains -s build.keychain
security set-key-partition-list -S apple-tool:,apple: -s -k "" build.keychain

mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
echo "$DEVELOPER_ID_PROFILE_BASE64" | base64 -d \
  > ~/Library/MobileDevice/Provisioning\ Profiles/sloop.provisionprofile

# archive + export, rather than signing the .app in place. This is what
# embeds the profile and expands $(AppIdentifierPrefix) in the entitlements.
# Manual signing style, because -allowProvisioningUpdates needs an
# authenticated Xcode and a runner has none.
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS -configuration Release \
  -archivePath build/Sloop.xcarchive \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$AC_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="<profile name>" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  archive

xcodebuild -exportArchive -archivePath build/Sloop.xcarchive \
  -exportOptionsPlist Scripts/ExportOptions-developer-id.plist \
  -exportPath build/export

# fail loudly if the profile did not make it in — the app would otherwise be
# killed on first launch on a user's Mac, and nothing else here would notice
test -f build/export/Sloop_macOS.app/Contents/embedded.provisionprofile

# zip, submit to Apple, wait, then staple the ticket onto the app
ditto -c -k --keepParent build/export/Sloop_macOS.app Sloop-macOS.zip
xcrun notarytool submit Sloop-macOS.zip \
  --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD" --wait
xcrun stapler staple build/export/Sloop_macOS.app
ditto -c -k --keepParent build/export/Sloop_macOS.app Sloop-macOS.zip   # re-zip stapled app
```

A notarized, stapled build opens on any Mac with no quarantine dance.

## iOS

iOS has no ad-hoc-download path at all — it needs a Developer account to run on
a device (development provisioning) and for TestFlight/App Store. Same account
unlocks both platforms.
