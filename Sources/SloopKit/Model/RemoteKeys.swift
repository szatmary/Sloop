// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Finding a private key in `~/.ssh` on a host, so it can be pulled into the
/// library.
///
/// This is the path that needs nothing installed on the user's desktop, which
/// is the whole reason it exists: iCloud Keychain cannot be reached from
/// Windows or Linux, but a Linux user's key is nearly always already sitting on
/// a machine they can SSH into.
///
/// Design: `Docs/superpowers/specs/2026-08-19-key-import-design.md`.
public enum RemoteKeys {
    /// The ceiling for a file read entirely into memory.
    ///
    /// An RSA-4096 private key is around 3 KB, so this is generous by more than
    /// an order of magnitude. It is not a guess at key sizes — it is the bound
    /// that stops "import a key" from being a way to pull an arbitrarily large
    /// file into a phone's memory when the user picks the wrong thing.
    public static let maximumBytes = 64 * 1024

    /// The conventional location, relative to a home directory.
    public static func directory(in home: String) -> String {
        RemotePath.normalize(home + "/.ssh")
    }

    /// Files in `sshDirectory` worth offering as private keys, sorted by name.
    ///
    /// Filtered by name alone. Classifying by content would mean reading every
    /// private key in the directory off the server merely to decide what to put
    /// in a list — which is exactly what a feature that copies key material
    /// must not do speculatively. The user picks, then one file is read.
    public static func candidates(in client: SFTPClient,
                                  sshDirectory: String) throws -> [SFTPEntry] {
        try client.list(sshDirectory)
            .filter { !$0.isDirectory && PrivateKeyMaterial.mayBePrivateKeyFile(named: $0.name) }
            .sorted { $0.name < $1.name }
    }

    /// Reads one candidate into memory, never onto disk.
    public static func read(_ entry: SFTPEntry, from client: SFTPClient) throws -> Data {
        try client.readData(entry.path, maximumBytes: maximumBytes)
    }
}
