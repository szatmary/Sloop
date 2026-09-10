#!/usr/bin/env bash
#
# Brick 2b of Mosh (M3): cross-compile mosh's libraries for Apple, consuming the
# protobuf.xcframework from brick 2a, and assemble Vendor/mosh.xcframework.
#
# mosh uses autotools + protobuf. We build a HOST protoc (native, protobuf 3.21)
# for codegen, then for each slice cross-`configure` mosh with the slice's target
# libprotobuf (from the downloaded protobuf.xcframework) and clang cross flags,
# `make` the noinst convenience libraries (skip the mosh-client/-server binaries,
# which don't link for iOS), and merge the resulting static libs.
#
# ⚠️ Blind cross-compile. This first version does ONE slice (ios-arm64) with heavy
# diagnostics to keep iterations fast; it fans out to all slices once green.
set -euo pipefail

# Shared dependency plumbing: the pinned ios-cmake tag, apply_patches, install_file.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/vendor.sh"

MOSH_TAG="mosh-1.4.0"
PROTOBUF_TAG="v21.12"
IOS_TARGET="17.0"
MACOS_TARGET="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.native-mosh"
OUT="$WORK/out"
HOSTPREFIX="$WORK/host"

# The protobuf.xcframework is provided by CI (download-artifact) or a prior local
# run of build-protobuf.sh.
PB_XCF="$ROOT/Vendor/protobuf.xcframework"
if [ ! -d "$PB_XCF" ]; then
  echo "Vendor/protobuf.xcframework missing — run build-protobuf.sh or download the artifact first."
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "==> Installing autotools (mosh uses autoconf/automake/libtool)"
for pkg in autoconf automake libtool pkg-config; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
# mosh's autogen calls libtoolize; on macOS Homebrew names it glibtoolize.
export LIBTOOLIZE=glibtoolize

echo "==> Fetching sources"
# No ios-cmake here: mosh is autotools and protobuf is built for the *host*
# only, so no CMake toolchain file is ever used. It was cloned on every run and
# never read.
git clone --depth 1 --branch "$PROTOBUF_TAG" https://github.com/protocolbuffers/protobuf.git
git clone https://github.com/mobile-shell/mosh.git
git -C mosh checkout --quiet "$MOSH_TAG"
# mosh's src/include/Makefile builds version.h from a top-level VERSION file
# (shipped in the dist tarball / created by git-describe). A plain tag checkout
# lacks it, so provide it.
echo "mosh ${MOSH_TAG#mosh-}" > mosh/VERSION

# One session per *thread*, not per process — mosh keeps session state in
# process-wide statics, which is safe for a one-session process and is not safe
# for Sloop's tabs. Each patch carries its own account of what breaks without
# it; see Scripts/deps/mosh/patches/.
apply_patches mosh mosh

# Mosh opens its own UDP socket and addresses every packet with sendto(). That
# is right for a host you can route to, and impossible for one you reach only
# through a tunnel: Sloop dials tailnet hosts with libtailscale, which hands
# back a connected datagram fd and no address to name. The patch adds a client
# constructor that adopts such an fd, sends with send() instead of sendto(),
# and skips port hopping — hopping the source port means nothing when the port
# the server sees belongs to the tunnel.
#
# A patch file rather than more sed: it is a dozen hunks across two files, and
# `git apply` fails loudly if upstream moves under it, which is the behaviour
# we want from every one of these.

echo "==> Building HOST protoc (native, protobuf $PROTOBUF_TAG)"
PB_CMAKE_SRC="protobuf/cmake"; test -f "$PB_CMAKE_SRC/CMakeLists.txt" || PB_CMAKE_SRC="protobuf"
cmake -S "$PB_CMAKE_SRC" -B build/pb-host -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOSTPREFIX" \
  -DCMAKE_CXX_STANDARD=17 \
  -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF \
  -Dprotobuf_BUILD_PROTOC_BINARIES=ON -Dprotobuf_INSTALL=ON
cmake --build build/pb-host --config Release -j"$(sysctl -n hw.ncpu)"
cmake --install build/pb-host --config Release
PROTOC="$HOSTPREFIX/bin/protoc"
test -x "$PROTOC" || { echo "host protoc not built"; find "$HOSTPREFIX" -name 'protoc*'; exit 1; }
echo "    host protoc: $($PROTOC --version)"

echo "==> autogen mosh"
( cd mosh && ./autogen.sh )

build_slice () {
  local name="$1" sdk="$2" min_flag="$3" triple="$4" pb_dir="$5"
  echo "==> Slice $name (sdk $sdk, triple $triple)"
  local sysroot cc cxx pbslice
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  cxx="$(xcrun --sdk "$sdk" --find clang++)"
  pbslice="$PB_XCF/$pb_dir"
  test -f "$pbslice/libprotobuf.a" || { echo "no libprotobuf.a in $pbslice"; ls -la "$PB_XCF"; exit 1; }
  local pbinc="$pbslice/Headers"

  local bdir="$WORK/build/mosh-$name"
  rm -rf "$bdir"; cp -R mosh "$bdir"

  # `-O2 -DNDEBUG` is in both flag strings above because setting CFLAGS at all
  # makes autoconf drop its own `-g -O2` default, and mosh's configure.ac never
  # defines NDEBUG. Without them every `assert()` in the library stayed live in
  # a shipped build — and where upstream mosh-client loses one process to an
  # abort, Sloop loses the app and every other tab with it. The framebuffer
  # diff, which runs on every frame, was also unoptimized.
  ( cd "$bdir" && ./configure \
      --host="$triple" \
      CC="$cc" CXX="$cxx" PROTOC="$PROTOC" \
      CFLAGS="-arch arm64 -isysroot $sysroot $min_flag -O2 -DNDEBUG" \
      CXXFLAGS="-arch arm64 -isysroot $sysroot $min_flag -std=c++17 -I$pbinc -O2 -DNDEBUG" \
      LDFLAGS="-arch arm64 -isysroot $sysroot $min_flag -L$pbslice" \
      protobuf_CFLAGS="-I$pbinc" protobuf_LIBS="-L$pbslice -lprotobuf" \
      TINFO_LIBS=" " \
      --disable-silent-rules ) || { echo "configure failed; tail of config.log:"; tail -60 "$bdir/config.log" || true; exit 1; }

  # The iOS SDK has no curses/terminfo (configure mis-detected it on the host).
  # Disable those defines so mosh's terminal takes its non-curses path — Sloop
  # renders mosh's framebuffer via SwiftTerm, so mosh's local terminfo Display
  # isn't needed.
  local cfg="$bdir/src/include/config.h"
  for m in HAVE_CURSES_H HAVE_NCURSES_H HAVE_NCURSESW_CURSES_H HAVE_NCURSES_CURSES_H HAVE_TERM_H HAVE_NCURSES_TERM_H HAVE_TERMIO_H; do
    sed -i.bak "s|#define $m 1|/* $m disabled for iOS */|" "$cfg"
  done
  rm -f "$cfg.bak"

  # Replace ONLY the init TU with a curses-free constructor, keeping
  # terminaldisplay.cc verbatim — the file explains why in its own header.
  install_file mosh terminaldisplayinit.cc "$bdir/src/terminal/terminaldisplayinit.cc"

  # Build the convenience libraries only (the frontend binaries won't link for
  # iOS; that's fine — we just want the .a's). Keep going past a failed binary.
  make -C "$bdir/src" -j"$(sysctl -n hw.ncpu)" || echo "    (make returned nonzero — expected if the frontend link failed; checking libs)"

  echo "==> static libs produced:"
  find "$bdir/src" -name '*.a'
  local libs
  libs=$(find "$bdir/src" -name 'libmosh*.a')
  # Require the client-critical libraries — a partial build must report red.
  for need in libmoshcrypto libmoshnetwork libmoshstatesync libmoshterminal libmoshprotos libmoshutil; do
    find "$bdir/src" -name "$need.a" | grep -q . || { echo "MISSING $need.a — build incomplete"; exit 1; }
  done

  mkdir -p "$OUT/$name/include"
  # shellcheck disable=SC2086
  libtool -static -o "$OUT/$name/libmosh.a" $libs "$pbslice/libprotobuf.a"
  echo "==> merged: $OUT/$name/libmosh.a"
}

# The app targets iOS (device + simulator) and macOS; tvOS was dropped, so skip
# it. pb_dir names match the slice identifiers in protobuf.xcframework.
build_slice "ios-arm64"      "iphoneos"        "-mios-version-min=$IOS_TARGET"            "arm-apple-darwin" "ios-arm64"
build_slice "ios-sim-arm64"  "iphonesimulator" "-mios-simulator-version-min=$IOS_TARGET"  "arm-apple-darwin" "ios-arm64-simulator"
build_slice "macos-arm64"    "macosx"          "-mmacosx-version-min=$MACOS_TARGET"       "arm-apple-darwin" "macos-arm64"

echo "==> Staging mosh headers (flat — mosh uses same-dir includes)"
# The C shim compiles against mosh's C++ API, so ship its headers. Stage them
# flat (all .h + generated .pb.h in one dir) so mosh's own "same-dir" includes
# resolve with a single header search path. Source is identical across slices,
# so collect once from the ios-arm64 build.
HDRS="$WORK/headers"
rm -rf "$HDRS"; mkdir -p "$HDRS"
find "$WORK/build/mosh-ios-arm64/src" \( -name '*.h' -o -name '*.hpp' \) -exec cp {} "$HDRS/" \;
# mosh's generated *.pb.h include <google/protobuf/...> (headers AND .inc files),
# so bundle protobuf's public headers under the same Headers dir. Without this
# the consumer app can't compile transportinstruction.pb.h. Protobuf is already
# merged into libmosh.a, so we ship only its headers here (not a second lib).
# Headers are identical across slices; copy the google/ tree from the ios slice.
cp -R "$PB_XCF/ios-arm64/Headers/google" "$HDRS/google"
echo "    staged $(find "$HDRS" -type f | wc -l | tr -d ' ') header files (mosh + protobuf)"

echo "==> Assembling mosh.xcframework"
rm -rf "$ROOT/Vendor/mosh.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libmosh.a"     -headers "$HDRS" \
  -library "$OUT/ios-sim-arm64/libmosh.a" -headers "$HDRS" \
  -library "$OUT/macos-arm64/libmosh.a"   -headers "$HDRS" \
  -output "$ROOT/Vendor/mosh.xcframework"

echo "==> Done: Vendor/mosh.xcframework (with headers)"
