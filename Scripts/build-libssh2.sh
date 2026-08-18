#!/usr/bin/env bash
#
# Cross-compile libssh2 (with an OpenSSL 3 crypto backend) into a multi-slice
# Vendor/libssh2.xcframework for iOS, iOS Simulator, and macOS — all arm64.
# Designed to run on a GitHub macOS runner.
#
# Why OpenSSL and not mbedTLS (which this script used until 2026-08):
#   - mbedTLS has no Ed25519, so ssh-ed25519 keys — the modern default — could
#     not be parsed, let alone used.
#   - libssh2's mbedTLS backend cannot derive a public key from a private key
#     in memory, so libssh2_userauth_publickey_frommemory required the caller
#     to supply the .pub blob or every key authentication failed.
# OpenSSL 3 handles Ed25519, ECDSA, and RSA (including rsa-sha2-256/512), and
# derives public keys from private ones. It is Apache-2.0, which is compatible
# with Sloop's GPL-3.0 licensing.
#
# tvOS slices are not built: OpenSSL ships no tvOS Configure target, and the
# tvOS app is deferred anyway (SwiftTerm doesn't compile for it — see
# Docs/ROADMAP.md). Add them here if that changes.
#
# Uses leetal/ios-cmake for libssh2's Apple toolchain files and merges libssh2 +
# libcrypto into one static library per slice so the xcframework is
# self-contained.
#
# Iterate on a single slice with:  SLICES="macos-arm64" Scripts/build-libssh2.sh
set -euo pipefail

OPENSSL_TAG="openssl-3.5.1"
LIBSSH2_TAG="libssh2-1.11.1"
# Pinned: ios.toolchain.cmake is executed CMake code that picks the compiler,
# sysroot and deployment flags for the crypto we ship. Tracking its default
# branch would let an upstream commit silently change the shipped binary.
IOS_CMAKE_TAG="4.6.0"
IOS_TARGET="17.0"
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.native"
OUT="$WORK/out"
TOOLCHAIN="$WORK/ios-cmake/ios.toolchain.cmake"
SLICES="${SLICES:-ios-arm64 ios-sim-arm64 macos-arm64}"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Fetching sources"
git clone --depth 1 --branch "$IOS_CMAKE_TAG" https://github.com/leetal/ios-cmake.git
git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git
git clone --depth 1 --branch "$LIBSSH2_TAG" https://github.com/libssh2/libssh2.git

# OpenSSL's build system is Configure + make, not CMake, so each slice gets an
# explicit SDK, arch, and deployment-target flag rather than a toolchain file.
build_openssl () {
  local name="$1" sdk="$2" target="$3" minflag="$4"
  local prefix="$WORK/prefix/$name"
  echo "==> OpenSSL: $name ($target, $sdk)"

  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local cc; cc="$(xcrun -f clang)"

  # A fresh checkout per slice: OpenSSL's Configure writes into the source tree
  # and cannot be reconfigured for a second target in place.
  rm -rf "openssl-$name"
  cp -R openssl "openssl-$name"
  (
    cd "openssl-$name"
    CC="$cc" \
    CFLAGS="-arch arm64 -isysroot $sysroot $minflag" \
    # --openssldir must NOT point into the build tree. OpenSSL bakes it into
    # libcrypto as OPENSSLDIR and auto-loads $OPENSSLDIR/openssl.cnf on first
    # use, so a build-tree path both leaks the builder's home directory into
    # every shipped binary (recoverable with `strings`) and names a
    # user-writable directory from which a planted config could load an
    # arbitrary provider module. libssh2 needs none of that machinery, so it
    # is disabled outright and the directory is pointed somewhere that cannot
    # exist.
    ./Configure "$target" \
      no-shared no-tests no-docs no-legacy no-engine \
      no-autoload-config no-module no-dso \
      --prefix="$prefix" --openssldir=/nonexistent
    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev
  )
}

build_libssh2 () {
  local name="$1" platform="$2" deploy="$3"
  local prefix="$WORK/prefix/$name"
  echo "==> libssh2: $name ($platform, deploy $deploy)"

  cmake -S libssh2 -B "build/libssh2-$name" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$platform" -DDEPLOYMENT_TARGET="$deploy" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DOPENSSL_INCLUDE_DIR="$prefix/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DENABLE_ZLIB_COMPRESSION=OFF
  cmake --build "build/libssh2-$name" --config Release -j"$(sysctl -n hw.ncpu)"
  cmake --install "build/libssh2-$name" --config Release

  # --- merge into one .a and collect headers ---
  # libssh2's OpenSSL backend needs libcrypto only (not libssl), so only that
  # is folded in; pulling in libssl would bloat every slice for nothing.
  mkdir -p "$OUT/$name/include"
  libtool -static -o "$OUT/$name/libssh2.a" \
    "$prefix/lib/libssh2.a" \
    "$prefix/lib/libcrypto.a"
  cp "$prefix/include/libssh2.h" "$prefix/include/libssh2_publickey.h" \
     "$prefix/include/libssh2_sftp.h" "$OUT/$name/include/"

  # Ship a module map inside the framework headers so Swift can `import CSSH`
  # once the xcframework is linked — no separate include path needed.
  cat > "$OUT/$name/include/module.modulemap" <<'MODMAP'
module CSSH {
    header "libssh2.h"
    // libssh2.h does not include the SFTP API; without this header the whole
    // of libssh2_sftp_* — and LIBSSH2_SFTP_ATTRIBUTES with it — is invisible to
    // Swift, which is what the Files.app integration is built on.
    header "libssh2_sftp.h"
    export *
}
MODMAP
}

build_slice () {
  local name="$1" sdk="$2" ossl_target="$3" minflag="$4" platform="$5" deploy="$6"
  case " $SLICES " in *" $name "*) ;; *) echo "==> Skipping $name"; return ;; esac
  build_openssl "$name" "$sdk" "$ossl_target" "$minflag"
  build_libssh2 "$name" "$platform" "$deploy"
}

build_slice "ios-arm64"     "iphoneos"        "ios64-cross"        "-mios-version-min=$IOS_TARGET"           "OS64"           "$IOS_TARGET"
build_slice "ios-sim-arm64" "iphonesimulator" "iossimulator-xcrun" "-mios-simulator-version-min=$IOS_TARGET" "SIMULATORARM64" "$IOS_TARGET"
build_slice "macos-arm64"   "macosx"          "darwin64-arm64-cc"  "-mmacosx-version-min=$MACOS_TARGET"      "MAC_ARM64"      "$MACOS_TARGET"

echo "==> Assembling xcframework"
args=()
for name in $SLICES; do
  args+=(-library "$OUT/$name/libssh2.a" -headers "$OUT/$name/include")
done
rm -rf "$ROOT/Vendor/libssh2.xcframework"
xcodebuild -create-xcframework "${args[@]}" -output "$ROOT/Vendor/libssh2.xcframework"

echo "==> Done: Vendor/libssh2.xcframework"
