#!/usr/bin/env bash
#
# Cross-compile libssh2 (with an mbedTLS crypto backend) into a multi-slice
# Vendor/libssh2.xcframework for iOS, iOS Simulator, macOS, tvOS, and tvOS
# Simulator — all arm64. Designed to run on a GitHub macOS runner.
#
# Uses leetal/ios-cmake for the Apple toolchain files and merges libssh2 +
# mbedTLS into one static library per slice so the xcframework is self-contained.
set -euo pipefail

MBEDTLS_TAG="mbedtls-3.6.2"
LIBSSH2_TAG="libssh2-1.11.1"
IOS_TARGET="17.0"
TVOS_TARGET="17.0"
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.native"
OUT="$WORK/out"
TOOLCHAIN="$WORK/ios-cmake/ios.toolchain.cmake"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Fetching sources"
git clone --depth 1 https://github.com/leetal/ios-cmake.git
git clone --depth 1 --branch "$MBEDTLS_TAG" --recursive https://github.com/Mbed-TLS/mbedtls.git
git clone --depth 1 --branch "$LIBSSH2_TAG" https://github.com/libssh2/libssh2.git

build_slice () {
  local name="$1" platform="$2" deploy="$3"
  local prefix="$WORK/prefix/$name"
  echo "==> Building slice: $name ($platform, deploy $deploy)"

  # --- mbedTLS (static) ---
  cmake -S mbedtls -B "build/mbedtls-$name" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$platform" -DDEPLOYMENT_TARGET="$deploy" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
  cmake --build "build/mbedtls-$name" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "build/mbedtls-$name" --config Release

  # --- libssh2 (static, mbedTLS backend) ---
  cmake -S libssh2 -B "build/libssh2-$name" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$platform" -DDEPLOYMENT_TARGET="$deploy" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCRYPTO_BACKEND=mbedTLS \
    -DMBEDTLS_ROOT_DIR="$prefix" \
    -DMBEDTLS_INCLUDE_DIR="$prefix/include" \
    -DMBEDTLS_LIBRARY="$prefix/lib/libmbedtls.a" \
    -DMBEDX509_LIBRARY="$prefix/lib/libmbedx509.a" \
    -DMBEDCRYPTO_LIBRARY="$prefix/lib/libmbedcrypto.a" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF
  cmake --build "build/libssh2-$name" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "build/libssh2-$name" --config Release

  # --- merge into one .a and collect headers ---
  mkdir -p "$OUT/$name/include"
  libtool -static -o "$OUT/$name/libssh2.a" \
    "$prefix/lib/libssh2.a" \
    "$prefix/lib/libmbedtls.a" \
    "$prefix/lib/libmbedx509.a" \
    "$prefix/lib/libmbedcrypto.a"
  cp "$prefix/include/libssh2.h" "$prefix/include/libssh2_publickey.h" \
     "$prefix/include/libssh2_sftp.h" "$OUT/$name/include/"

  # Ship a module map inside the framework headers so Swift can `import CSSH`
  # once the xcframework is linked — no separate include path needed.
  cat > "$OUT/$name/include/module.modulemap" <<'MODMAP'
module CSSH {
    header "libssh2.h"
    export *
}
MODMAP
}

build_slice "ios-arm64"       "OS64"                "$IOS_TARGET"
build_slice "ios-sim-arm64"   "SIMULATORARM64"      "$IOS_TARGET"
build_slice "macos-arm64"     "MAC_ARM64"           "$MACOS_TARGET"
build_slice "tvos-arm64"      "TVOS"                "$TVOS_TARGET"
build_slice "tvos-sim-arm64"  "SIMULATORARM64_TVOS" "$TVOS_TARGET"

echo "==> Assembling xcframework"
rm -rf "$ROOT/Vendor/libssh2.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libssh2.a"      -headers "$OUT/ios-arm64/include" \
  -library "$OUT/ios-sim-arm64/libssh2.a"  -headers "$OUT/ios-sim-arm64/include" \
  -library "$OUT/macos-arm64/libssh2.a"    -headers "$OUT/macos-arm64/include" \
  -library "$OUT/tvos-arm64/libssh2.a"     -headers "$OUT/tvos-arm64/include" \
  -library "$OUT/tvos-sim-arm64/libssh2.a" -headers "$OUT/tvos-sim-arm64/include" \
  -output "$ROOT/Vendor/libssh2.xcframework"

echo "==> Done: Vendor/libssh2.xcframework"
