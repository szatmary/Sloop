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
# Full clone + checkout (a shallow clone of mosh's annotated tag leaves a bad
# working tree — "is not a commit").
git clone https://github.com/mobile-shell/mosh.git
git -C "$SRC" checkout --quiet "$MOSH_TAG"

echo "==> Locating crypto sources"
# Find the crypto directory by name (robust to file naming), not a specific file.
CRYPTO_DIR="$(find "$SRC" -type d -name crypto | head -1)"
if [ -z "$CRYPTO_DIR" ] || [ ! -d "$CRYPTO_DIR" ]; then
  echo "no crypto dir found under $SRC; directory tree:"
  find "$SRC" -maxdepth 3 -type d | sort
  exit 1
fi
SRC_ROOT="$(dirname "$CRYPTO_DIR")"           # .../src
echo "    crypto dir: $CRYPTO_DIR"
echo "==> crypto dir contents:"
ls -la "$CRYPTO_DIR"
echo "==> headers included by crypto sources (reveals any OpenSSL/nettle dep):"
grep -h '#include' "$CRYPTO_DIR"/*.cc 2>/dev/null | sort -u || true

# bash 3.2 on the macOS runner has no `mapfile`.
CRYPTO_TUS=()
while IFS= read -r f; do CRYPTO_TUS+=("$f"); done < <(find "$CRYPTO_DIR" -maxdepth 1 -name '*.cc')
echo "    crypto TUs: ${CRYPTO_TUS[*]}"
INCLUDES=(-I "$SRC" -I "$CRYPTO_DIR" -I "$SRC_ROOT" -I "$SRC_ROOT/util" -I "$SRC_ROOT/include")

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
build_slice () {
  local name="$1" sdk="$2" min_flag="$3"
  echo "==> Building slice: $name (sdk $sdk)"
  local sysroot clangxx obj_dir
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clangxx="$(xcrun --sdk "$sdk" --find clang++)"
  obj_dir="$WORK/obj/$name"
  mkdir -p "$obj_dir" "$OUT/$name/include"

  for tu in "${CRYPTO_TUS[@]}"; do   # absolute paths from find
    local base
    base="$(basename "$tu" .cc)"
    "$clangxx" -c -std=c++17 -arch arm64 -isysroot "$sysroot" "$min_flag" \
      "${INCLUDES[@]}" "$tu" -o "$obj_dir/$base.o"
  done

  ar rcs "$OUT/$name/libmoshcrypto.a" "$obj_dir"/*.o

  # Ship the crypto headers (C++), for the C-shim brick that comes next.
  cp "$CRYPTO_DIR/crypto.h" "$CRYPTO_DIR/ae.h" "$OUT/$name/include/" 2>/dev/null || true
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
