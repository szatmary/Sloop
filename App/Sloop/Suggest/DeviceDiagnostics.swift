// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A debug-build log file in the app's Documents directory.
///
/// The two obvious channels both fail on a device. `print` goes to stdout,
/// which only exists when the app was launched with a console attached — and
/// Swift block-buffers it when stdout is a pipe, so lines arrive late or not at
/// all. `os_log` goes to the unified log, which can only be collected from a
/// device by a root process on the Mac. A file in the app container needs
/// neither: `devicectl device copy from` pulls it whenever, however the app was
/// started.
///
/// Debug builds only. Nothing here should ship: these lines describe what the
/// user typed and what was suggested back.
enum DeviceDiagnostics {
    #if DEBUG
    private static let queue = DispatchQueue(label: "org.szatmary.sloop.diagnostics")
    private static let url: URL? = {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("sloop-diagnostics.log")
    }()
    #endif

    static func log(_ message: String) {
        #if DEBUG
        guard let url else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        #endif
    }
}
