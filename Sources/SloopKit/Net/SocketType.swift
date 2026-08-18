// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Sources/SloopKit/Net/SocketType.swift
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `SOCK_STREAM`'s type differs across platforms (plain `Int32` on Darwin,
/// `__socket_type` on Glibc). This is the one shared, correctly-typed
/// constant that both `Dialer` and `SocketPairRelay` build their
/// `socket()`/`socketpair()` calls from.
#if canImport(Glibc)
let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
let sockStreamType = SOCK_STREAM
#endif
