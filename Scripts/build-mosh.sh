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

MOSH_TAG="mosh-1.4.0"
PROTOBUF_TAG="v21.12"
IOS_TARGET="17.0"

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
git clone --depth 1 https://github.com/leetal/ios-cmake.git
git clone --depth 1 --branch "$PROTOBUF_TAG" https://github.com/protocolbuffers/protobuf.git
git clone https://github.com/mobile-shell/mosh.git
git -C mosh checkout --quiet "$MOSH_TAG"
# mosh's src/include/Makefile builds version.h from a top-level VERSION file
# (shipped in the dist tarball / created by git-describe). A plain tag checkout
# lacks it, so provide it.
echo "mosh ${MOSH_TAG#mosh-}" > mosh/VERSION

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

# Build a single slice for now.
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

  ( cd "$bdir" && ./configure \
      --host="$triple" \
      CC="$cc" CXX="$cxx" PROTOC="$PROTOC" \
      CFLAGS="-arch arm64 -isysroot $sysroot $min_flag" \
      CXXFLAGS="-arch arm64 -isysroot $sysroot $min_flag -std=c++17 -I$pbinc" \
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

  # mosh's Display (terminaldisplay*.cc) is the local terminfo renderer and the
  # only thing that needs curses. Sloop renders mosh's framebuffer via SwiftTerm
  # and never constructs a Display, so stub these out (empty TUs) instead of
  # cross-compiling ncurses for iOS. The rest of the terminal lib
  # (Framebuffer/Emulator/Parser, needed by statesync) is untouched.
  : > "$bdir/src/terminal/terminaldisplay.cc"
  : > "$bdir/src/terminal/terminaldisplayinit.cc"

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

build_slice "ios-arm64" "iphoneos" "-mios-version-min=$IOS_TARGET" "arm-apple-darwin" "ios-arm64"

echo "==> (single-slice bring-up) libmosh.a built for ios-arm64; xcframework assembly added once all slices compile."
