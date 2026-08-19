# `CTailscale` — a module map for libtailscale, kept outside the xcframework

`TailscaleNode` and `TailscaleDialer` live in the **SloopSSH framework**, so the
File Provider extension can reach a tailnet too. Framework targets cannot use an
Objective-C bridging header, which is how the app used to see tsnet's C API — so
libtailscale needs a real Clang module.

It cannot get one the way libssh2 does. Xcode copies every linked xcframework's
headers into a single `$(BUILT_PRODUCTS_DIR)/include` directory, and libssh2
already ships a `module.modulemap` there. A second one is not a module conflict,
it is a *file* conflict:

    error: Multiple commands produce '…/Build/Products/Debug/include/module.modulemap'

So the map lives here instead, one per platform, pointing back into the
xcframework slice. The targets add:

    SWIFT_INCLUDE_PATHS = $(SRCROOT)/Vendor/CTailscale/$(PLATFORM_NAME)

`PLATFORM_NAME` is `macosx`, `iphoneos`, or `iphonesimulator`, which is why the
directories are named that way rather than after the xcframework's own slice
names. One iOS target covers both device and simulator, so the substitution has
to happen at build time.

These files are checked in; the xcframework they point at is not (see
`.gitignore` and `Docs/MOSH.md`/`Scripts/build-libtailscale.sh`). A missing
xcframework fails as an unresolved header, not a confusing module error.
