#!/usr/bin/env bash
#
# Shared plumbing for the Vendor/*.xcframework build scripts.
#
# Two jobs, kept apart on purpose because they are different things that used to
# look the same:
#
#   apply_patches — edits to *upstream* source. Real unified diffs under
#                   Scripts/deps/<dep>/patches/, applied with `git apply`.
#   install_file  — files *Sloop owns* that upstream has no opinion about, kept
#                   under Scripts/deps/<dep>/files/ and copied into place.
#
# Both used to be `sed -i` and heredocs inside the build scripts. That made the
# edits invisible to review (a diff of a heredoc tells you nothing about what
# the resulting file looks like), and it meant the only copy of a file Sloop
# authored — libssh2's module map, for one — lived inside a generated artifact
# that .gitignore excludes. When that file turned out to be wrong there was
# nothing in the repository to fix.
#
# Source this from a build script:
#     . "$(dirname "$0")/lib/vendor.sh"

set -euo pipefail

VENDOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="$(cd "$VENDOR_LIB_DIR/../deps" && pwd)"

# ios-cmake supplies ios.toolchain.cmake, which is *executed* CMake code: it
# picks the compiler, sysroot and deployment flags for everything cross-compiled
# here. Tracking its default branch would let an upstream commit silently change
# the shipped binaries, so it is pinned — once, here, rather than in each script
# that clones it. build-libssh2.sh pinned it and build-mosh.sh / build-protobuf.sh
# did not, which is the kind of drift a single definition prevents.
IOS_CMAKE_TAG="${IOS_CMAKE_TAG:-4.6.0}"

# apply_patches <source-dir> <dep>
#
# Applies every patch in Scripts/deps/<dep>/patches/, in filename order.
#
# `git apply` verifies context itself and names the file and hunk it could not
# place, so there is no follow-up grep to confirm the edit landed — the old
# `sed … || echo "upstream moved"` pair could only report *that* something was
# wrong, never where. --check first so a partly-applied series never leaves a
# half-patched tree behind.
apply_patches () {
  local src="$1" dep="$2"
  local dir="$DEPS_DIR/$dep/patches"

  [ -d "$dir" ] || return 0
  local patches=("$dir"/*.patch)
  [ -e "${patches[0]}" ] || return 0

  for patch in "${patches[@]}"; do
    echo "==> Patching $dep: $(basename "$patch")"
    if ! git -C "$src" apply --check "$patch" 2>/dev/null; then
      # Already applied is not a failure: the build scripts are re-run against
      # an existing checkout constantly during development.
      if git -C "$src" apply --reverse --check "$patch" 2>/dev/null; then
        echo "    already applied, skipping"
        continue
      fi
      echo "ERROR: $(basename "$patch") does not apply to $src." >&2
      echo "       Upstream has moved. Re-cut the patch against the pinned tag;" >&2
      echo "       do not edit the source in place." >&2
      git -C "$src" apply --check "$patch" >&2 || true
      exit 1
    fi
    git -C "$src" apply "$patch"
  done
}

# install_file <dep> <relative-path-under-files> <destination>
#
# Copies a Sloop-authored file into the build or output tree. The destination's
# directory must already exist — every caller is placing a file next to others
# it just produced, so a missing directory means the caller is wrong about where
# it is, and creating it silently would hide that.
install_file () {
  local dep="$1" name="$2" dest="$3"
  local src="$DEPS_DIR/$dep/files/$name"

  [ -f "$src" ] || { echo "ERROR: missing $src" >&2; exit 1; }
  [ -d "$(dirname "$dest")" ] || {
    echo "ERROR: $(dirname "$dest") does not exist; cannot install $name" >&2
    exit 1
  }
  cp "$src" "$dest"
}

# append_file <dep> <relative-path-under-files> <destination>
#
# Adds a Sloop-authored fragment to the end of a file that came from upstream.
# `install_file` would replace it; this is for the case where upstream's
# contents must survive — libtailscale's tailscale.h, which gains one exported
# declaration and keeps everything else.
append_file () {
  local dep="$1" name="$2" dest="$3"
  local src="$DEPS_DIR/$dep/files/$name"

  [ -f "$src" ] || { echo "ERROR: missing $src" >&2; exit 1; }
  [ -f "$dest" ] || { echo "ERROR: $dest does not exist; cannot append $name" >&2; exit 1; }
  cat "$src" >> "$dest"
}
