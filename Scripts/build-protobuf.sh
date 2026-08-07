#!/usr/bin/env bash
#
# Brick 2a of Mosh (M3): cross-compile a mosh-compatible Protocol Buffers
# runtime (v3.21 — the last pre-abseil release; Homebrew's modern abseil-based
# protobuf fails mosh 1.4's configure) into Vendor/protobuf.xcframework for the
# Apple arm64 slices. mosh links this; the full mosh build (brick 2b) consumes
# the same per-slice static libs.
#
# Reuses the libssh2 recipe: leetal/ios-cmake toolchain + CMake, runtime only
# (no protoc/libprotoc for the target — the host protoc is used at mosh build
# time). Designed to run on a GitHub macOS runner.
#
# ⚠️ Blind cross-compile; expect a fix-up pass on first CI run.
set -euo pipefail

PROTOBUF_TAG="v21.12"          # protobuf 3.21.12, pre-abseil
IOS_TARGET="17.0"
TVOS_TARGET="17.0"
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.native-protobuf"
OUT="$WORK/out"
TOOLCHAIN="$WORK/ios-cmake/ios.toolchain.cmake"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Fetching sources"
git clone --depth 1 https://github.com/leetal/ios-cmake.git
git clone --depth 1 --branch "$PROTOBUF_TAG" https://github.com/protocolbuffers/protobuf.git

# protobuf 3.21 keeps its CMake project under cmake/.
PB_CMAKE_SRC="protobuf/cmake"
test -f "$PB_CMAKE_SRC/CMakeLists.txt" || PB_CMAKE_SRC="protobuf"

build_slice () {
  local name="$1" platform="$2" deploy="$3"
  local prefix="$WORK/prefix/$name"
  echo "==> Building slice: $name ($platform, deploy $deploy)"

  cmake -S "$PB_CMAKE_SRC" -B "build/protobuf-$name" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$platform" -DDEPLOYMENT_TARGET="$deploy" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_CXX_STANDARD=17 \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_LIBPROTOC=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_WITH_ZLIB=OFF \
    -Dprotobuf_INSTALL=ON
  cmake --build "build/protobuf-$name" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "build/protobuf-$name" --config Release

  mkdir -p "$OUT/$name"
  # The runtime static lib may be named libprotobuf.a (with a possible 'd' suffix
  # in Debug — we build Release).
  local lib
  lib="$(find "$prefix" -name 'libprotobuf.a' | head -1)"
  test -n "$lib" || { echo "libprotobuf.a not found under $prefix"; find "$prefix" -name '*.a'; exit 1; }
  cp "$lib" "$OUT/$name/libprotobuf.a"
  cp -R "$prefix/include" "$OUT/$name/include"
}

build_slice "ios-arm64"       "OS64"                "$IOS_TARGET"
build_slice "ios-sim-arm64"   "SIMULATORARM64"      "$IOS_TARGET"
build_slice "macos-arm64"     "MAC_ARM64"           "$MACOS_TARGET"
build_slice "tvos-arm64"      "TVOS"                "$TVOS_TARGET"
build_slice "tvos-sim-arm64"  "SIMULATORARM64_TVOS" "$TVOS_TARGET"

echo "==> Assembling xcframework"
rm -rf "$ROOT/Vendor/protobuf.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libprotobuf.a"      -headers "$OUT/ios-arm64/include" \
  -library "$OUT/ios-sim-arm64/libprotobuf.a"  -headers "$OUT/ios-sim-arm64/include" \
  -library "$OUT/macos-arm64/libprotobuf.a"    -headers "$OUT/macos-arm64/include" \
  -library "$OUT/tvos-arm64/libprotobuf.a"     -headers "$OUT/tvos-arm64/include" \
  -library "$OUT/tvos-sim-arm64/libprotobuf.a" -headers "$OUT/tvos-sim-arm64/include" \
  -output "$ROOT/Vendor/protobuf.xcframework"

echo "==> Done: Vendor/protobuf.xcframework"
