//
//  Sloop-Bridging-Header.h
//  Sloop
//
//  Objective-C → Swift bridge. project.ssh.yml and project.mosh.yml both set
//  SWIFT_OBJC_BRIDGING_HEADER to this file, so these C symbols are visible to
//  Swift in the SSH-enabled variants and nowhere else — matching the
//  `#if canImport(CSSH)` gate used across the SSH sources.
//
//  Each include is guarded, because the variants layer: the SSH build has
//  libssh2 but no mosh and no tailscale. They cannot be module maps —
//  libssh2.xcframework already ships one, and Xcode copies every xcframework's
//  headers into a single include/ directory where two module.modulemap files
//  collide.
//

#if __has_include("MoshBridge.h")
#import "MoshBridge.h"
#endif

#if __has_include(<libssh2.h>)
#import "libssh2-internal.h"
#endif

#if __has_include(<tailscale.h>)
#include <tailscale.h>
#endif
