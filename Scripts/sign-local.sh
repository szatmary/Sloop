#!/usr/bin/env bash
#
# Make a downloaded or locally-built Sloop.app runnable on THIS Mac without an
# Apple Developer account.
#
# What it does: clears the download quarantine flag and applies an ad-hoc code
# signature (identity "-", no account/cert required) so the arm64 binary is
# valid to execute.
#
# What it does NOT do: get past Gatekeeper on other people's machines. Only a
# Developer ID signature + Apple notarization does that. A self-signed
# *certificate* would not help here either — Gatekeeper checks notarization,
# not local certificate trust. Notarization is the real ship step.
#
# Usage:  Scripts/sign-local.sh /path/to/Sloop.app
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 /path/to/Sloop.app" >&2
  exit 1
fi

echo "==> Clearing quarantine (com.apple.quarantine) on $APP"
xattr -cr "$APP"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Done. Launch it with:"
echo "    open \"$APP\""
