#!/usr/bin/env bash
# Build libtailscale (Tailscale's C API over tsnet) as Vendor/libtailscale.xcframework.
#
# This is what lets Sloop join a tailnet itself, instead of relying on the
# Tailscale app's system VPN. tsnet is a userspace WireGuard node: it needs no
# VPN entitlement, coexists with whatever else holds the VPN slot (on iOS only
# one may), and hands back a real socket fd per dial — which is exactly the
# shape of Sloop's `Dialer` seam, so libssh2 needs no changes at all.
#
# Requires a Go toolchain (the only part of Sloop that does; mosh and libssh2
# are C/C++). Go cross-compiles to iOS through cgo with the platform SDK, so
# there is no gomobile dependency here.
#
# Generate the project with `xcodegen generate --spec project.tailscale.yml`
# afterwards; the base/SSH/Mosh variants stay lean and don't link this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.native-tailscale"
OUT="$WORK/out"
XCF="$ROOT/Vendor/libtailscale.xcframework"

IOS_TARGET="17.0"
MACOS_TARGET="14.0"

command -v go >/dev/null || { echo "Go toolchain not found — brew install go"; exit 1; }
echo "==> $(go version)"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

if [ ! -d libtailscale ]; then
  echo "==> Fetching libtailscale"
  git clone --quiet --depth 1 https://github.com/tailscale/libtailscale
fi
cd libtailscale

# libtailscale can start a node and dial over it, but has no way to ask what the
# node is doing — and both answers a UI needs live on the status tsnet already
# has: whether it is running, and the URL to authorize this device when it
# isn't. Add an export that returns them, rather than scraping the URL out of
# tsnet's log, which reads a debugging aid as an API and fails by stranding the
# user at a login they cannot start.
cp "$ROOT/Scripts/libtailscale-sloop-status.go" ./sloop_status.go

# One slice per platform. Go names the iOS device platform "ios"; the simulator
# is the same GOOS with a simulator sysroot and an explicit -target, since the
# SDK alone doesn't distinguish them to the linker.
build_slice () {
  local name="$1" goos="$2" sdk="$3" target="$4"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local flags="-target $target -isysroot $sysroot"

  echo "==> Building $name"
  CGO_ENABLED=1 GOOS="$goos" GOARCH=arm64 \
    CC="$(xcrun --find clang)" \
    CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
    go build -buildmode=c-archive -o "$OUT/$name/libtailscale.a" .

  # Headers only, no module map. libssh2.xcframework already ships one at
  # Headers/module.modulemap, and Xcode copies every xcframework's headers into
  # the same include/ directory — two of them collide there ("Multiple commands
  # produce .../include/module.modulemap"). Swift reaches these declarations
  # through the bridging header instead, which is how the Mosh bridge is wired
  # too.
  rm -rf "$OUT/$name/Headers"
  mkdir -p "$OUT/$name/Headers"
  cp tailscale.h "$OUT/$name/Headers/"
  # Declare the added export alongside upstream's API. cgo emits it as a plain
  # C symbol, so nothing else is needed to call it.
  cat >> "$OUT/$name/Headers/tailscale.h" <<'EOF'

// Added by Sloop (Scripts/libtailscale-sloop-status.go): writes
// "<BackendState>\n<AuthURL>" into buf. BackendState is tsnet's own
// vocabulary ("NeedsLogin", "Starting", "Running"); AuthURL is empty unless
// this device is waiting to be authorized.
extern int TsnetSloopStatus(int sd, char* buf, size_t buflen);
EOF
}

build_slice "ios-arm64"     "ios"    "iphoneos"        "arm64-apple-ios$IOS_TARGET"
build_slice "ios-sim-arm64" "ios"    "iphonesimulator" "arm64-apple-ios$IOS_TARGET-simulator"
build_slice "macos-arm64"   "darwin" "macosx"          "arm64-apple-macos$MACOS_TARGET"

echo "==> Assembling $XCF"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libtailscale.a"     -headers "$OUT/ios-arm64/Headers" \
  -library "$OUT/ios-sim-arm64/libtailscale.a" -headers "$OUT/ios-sim-arm64/Headers" \
  -library "$OUT/macos-arm64/libtailscale.a"   -headers "$OUT/macos-arm64/Headers" \
  -output "$XCF"

echo "==> Done"
find "$XCF" -name 'libtailscale.a' -exec ls -lh {} \;
