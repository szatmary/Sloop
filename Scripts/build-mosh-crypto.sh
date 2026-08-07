#!/usr/bin/env bash
#
# Brick 1 of Mosh support: prove that mosh's C++ cross-compiles for every Apple
# arm64 slice by building its self-contained crypto (AES + OCB — the AEAD that
# protects every SSP datagram) into Vendor/mosh-crypto.xcframework.
#
# This deliberately avoids protobuf and mosh's autotools link step: it runs
# mosh's ./configure natively only to GENERATE config.h, then compiles the
# crypto translation units directly with clang for each target slice. Designed
# to run on a GitHub macOS runner.
#
# ⚠️ Blind cross-compile — the exact crypto source/include set is best-effort and
# may need a fix-up pass on first CI run (missing TU, include dir, or an
# OpenSSL-vs-bundled-OCB config.h toggle).
set -euo pipefail

MOSH_TAG="mosh-1.4.0"
IOS_TARGET="17.0"
TVOS_TARGET="17.0"
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.native-mosh"
OUT="$WORK/out"
SRC="$WORK/mosh"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Installing build deps (protobuf/automake only needed so configure passes)"
brew list protobuf   >/dev/null 2>&1 || brew install protobuf
brew list automake   >/dev/null 2>&1 || brew install automake
brew list pkg-config >/dev/null 2>&1 || brew install pkg-config

echo "==> Fetching mosh $MOSH_TAG"
git clone --depth 1 --branch "$MOSH_TAG" https://github.com/mobile-shell/mosh.git

echo "==> Native configure (to generate config.h)"
cd "$SRC"
./autogen.sh
# We only need config.h; a native configure is fine. Don't fail the whole build
# if configure is unhappy about optional bits — we just need the header.
./configure || true
test -f config.h || { echo "config.h was not generated"; exit 1; }
cd "$WORK"

# The self-contained crypto translation units. If mosh's config.h selected an
# OpenSSL OCB path this list/'-I' set will need adjusting (next CI pass).
CRYPTO_TUS=(
  "src/crypto/aes.cc"
  "src/crypto/ocb.cc"
  "src/crypto/crypto.cc"
  "src/crypto/base64.cc"
)
INCLUDES=(-I "$SRC" -I "$SRC/src/crypto" -I "$SRC/src/util" -I "$SRC/src/include")

build_slice () {
  local name="$1" sdk="$2" min_flag="$3"
  echo "==> Building slice: $name (sdk $sdk)"
  local sysroot clangxx obj_dir
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clangxx="$(xcrun --sdk "$sdk" --find clang++)"
  obj_dir="$WORK/obj/$name"
  mkdir -p "$obj_dir" "$OUT/$name/include"

  for tu in "${CRYPTO_TUS[@]}"; do
    local base
    base="$(basename "$tu" .cc)"
    "$clangxx" -c -std=c++17 -arch arm64 -isysroot "$sysroot" "$min_flag" \
      "${INCLUDES[@]}" "$SRC/$tu" -o "$obj_dir/$base.o"
  done

  ar rcs "$OUT/$name/libmoshcrypto.a" "$obj_dir"/*.o

  # Ship the crypto headers (C++), for the C-shim brick that comes next.
  cp "$SRC/src/crypto/crypto.h" "$SRC/src/crypto/ae.h" "$OUT/$name/include/" 2>/dev/null || true
}

build_slice "ios-arm64"       "iphoneos"           "-mios-version-min=$IOS_TARGET"
build_slice "ios-sim-arm64"   "iphonesimulator"    "-mios-simulator-version-min=$IOS_TARGET"
build_slice "macos-arm64"     "macosx"             "-mmacosx-version-min=$MACOS_TARGET"
build_slice "tvos-arm64"      "appletvos"          "-mtvos-version-min=$TVOS_TARGET"
build_slice "tvos-sim-arm64"  "appletvsimulator"   "-mtvos-simulator-version-min=$TVOS_TARGET"

echo "==> Assembling xcframework"
rm -rf "$ROOT/Vendor/mosh-crypto.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libmoshcrypto.a"      -headers "$OUT/ios-arm64/include" \
  -library "$OUT/ios-sim-arm64/libmoshcrypto.a"  -headers "$OUT/ios-sim-arm64/include" \
  -library "$OUT/macos-arm64/libmoshcrypto.a"    -headers "$OUT/macos-arm64/include" \
  -library "$OUT/tvos-arm64/libmoshcrypto.a"     -headers "$OUT/tvos-arm64/include" \
  -library "$OUT/tvos-sim-arm64/libmoshcrypto.a" -headers "$OUT/tvos-sim-arm64/include" \
  -output "$ROOT/Vendor/mosh-crypto.xcframework"

echo "==> Done: Vendor/mosh-crypto.xcframework"
