//
//  Sloop-Bridging-Header.h
//  Sloop
//
//  Objective-C → Swift bridge. project.ssh.yml and project.mosh.yml both set
//  SWIFT_OBJC_BRIDGING_HEADER to this file, so these C symbols are visible to
//  Swift in the SSH-enabled variants and nowhere else — matching the
//  `#if canImport(CSSH)` gate used across the SSH sources.
//
//  The angle-bracket guards below are load-bearing, because the variants
//  layer: the SSH build links libssh2 but not tailscale, so only the variant
//  that puts a header on the search path gets the declarations that need it.
//  They cannot be module maps — libssh2.xcframework already ships one, and
//  Xcode copies every xcframework's headers into a single include/ directory
//  where two module.modulemap files collide.
//

// Not a variant guard, despite appearances: a quote-include resolves relative
// to this file's own directory first, and MoshBridge.h always sits beside it,
// so this is found in every build. That is fine — MoshBridge.h is
// self-contained plain C that declares functions without requiring mosh. The
// real gating is in MoshBridge.mm (which needs mosh's own headers) and behind
// `#if SLOOP_MOSH` in MoshTransport.swift.
#if __has_include("MoshBridge.h")
#import "MoshBridge.h"
#endif

#if __has_include(<libssh2.h>)
#import "libssh2-internal.h"
#endif

#if __has_include(<tailscale.h>)
#include <tailscale.h>
#endif
