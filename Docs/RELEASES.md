# Releases

Sloop's macOS app is built by CI (`.github/workflows/ci.yml`, the `mac-release`
job) and published to the repo's **Releases** page — no local Xcode needed.

All builds are currently **unsigned** (arm64 / Apple Silicon, SSH-enabled).
macOS Gatekeeper blocks unsigned apps on first launch: right-click the app and
choose **Open**. Code signing / notarization comes later.

## Nightly (rolling)

Every push to `main` refreshes a pre-release tagged **`nightly`** with the newest
macOS build attached (`Sloop-macOS.zip`). The `nightly` tag always points at the
latest `main` commit, so its download URL is stable:

    https://github.com/szatmary/Sloop/releases/tag/nightly

## Versioned releases

To cut a stable, permanent release, push a `v*` tag:

    git tag v0.1.0
    git push origin v0.1.0

CI builds the app and publishes a release named after the tag with
`Sloop-macOS.zip` attached. Versioned releases are immutable — the tag pins the
exact commit, unlike `nightly` which moves.

## What's not here yet

- **Signing / notarization** — builds are unsigned; Gatekeeper needs the
  right-click → Open workaround.
- **iOS / TestFlight** — the iOS app is built in CI but not distributed; that
  needs an Apple Developer account and signing.
