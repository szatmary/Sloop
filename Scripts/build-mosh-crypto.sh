#!/usr/bin/env bash
#
# Brick 1 of Mosh support: prove that mosh's C++ cross-compiles for every Apple
# arm64 slice by building its self-contained crypto (AES + OCB — the AEAD that
# protects every SSP datagram) into Vendor/mosh-crypto.xcframework.
#
# This deliberately avoids protobuf and mosh's autotools entirely: the crypto
# translation units are protobuf-free, so instead of running mosh's ./configure
# (which requires a matching protobuf and fails against Homebrew's modern
# abseil-based protobuf), we hand-write a minimal config.h — all HAVE_* left
# undefined so mosh takes its portable fallbacks — and compile the crypto sources
# directly with clang for each Apple slice. Designed to run on a GitHub macOS
# runner.
#
# ⚠️ Blind cross-compile — the exact crypto source/include set is best-effort and
# may need a fix-up pass on first CI run (a missing translation unit, an include
# dir, or a HAVE_* the crypto path actually needs).
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

echo "==> Fetching mosh $MOSH_TAG"
git clone --depth 1 --branch "$MOSH_TAG" https://github.com/mobile-shell/mosh.git

echo "==> Writing minimal config.h (crypto is protobuf-free; no autotools needed)"
# The crypto TUs #include "config.h". A minimal one with everything HAVE_*
# undefined makes mosh use its portable code paths (little-endian, manual secure
# zero, bundled OCB). Add HAVE_* here only if a crypto TU actually demands it.
cat > "$SRC/config.h" <<'CONFIG_H'
#ifndef SLOOP_MOSH_MINIMAL_CONFIG_H
#define SLOOP_MOSH_MINIMAL_CONFIG_H
#define PACKAGE_STRING  "mosh 1.4.0"
#define PACKAGE_VERSION "1.4.0"
#endif
CONFIG_H

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
