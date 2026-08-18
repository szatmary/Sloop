//
//  Sloop-Bridging-Header.h
//  Sloop
//
//  Objective-C → Swift bridge. Only the SSH-enabled project (project.ssh.yml)
//  sets SWIFT_OBJC_BRIDGING_HEADER to this file, so these C symbols are visible
//  to Swift only in that build variant — matching the `#if canImport(CSSH)`
//  gate used across the SSH sources.
//

#import "MoshBridge.h"

// Only the Tailscale variant (project.tailscale.yml) puts libtailscale's header
// on the search path, so this is how Swift sees tsnet's C API there and nowhere
// else. It cannot be a module map: libssh2.xcframework already ships one, and
// Xcode copies every xcframework's headers into a single include/ directory
// where two module.modulemap files collide.
#if __has_include(<tailscale.h>)
#include <tailscale.h>
#endif
