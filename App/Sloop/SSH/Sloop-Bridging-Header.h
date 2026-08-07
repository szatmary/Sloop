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
