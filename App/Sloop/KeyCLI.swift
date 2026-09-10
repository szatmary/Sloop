// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
import SloopSSH

#if os(macOS)
/// Key-library subcommands embedded in the app binary, so imports run with
/// the app's signature and entitlements (a plain script cannot write the
/// shared, synchronizable keychain). Invoked via Scripts/sloop:
///
///     sloop import-key ~/.ssh/id_ed25519 [--name work] [--force]
///     sloop list-keys
///     sloop remove-key work
enum KeyCLI {
    enum Command: Equatable {
        case importKey(path: String, name: String?, force: Bool)
        case listKeys
        case removeKey(name: String)
        case usage
    }

    /// nil = not a CLI invocation; launch the GUI.
    static func parse(_ arguments: [String]) -> Command? {
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "import-key":
            guard arguments.count >= 3 else { return .usage }
            let path = arguments[2]
            var name: String?
            var force = false
            var i = 3
            // --name and --force may each appear at most once, in either
            // order (`--force --name x` and `--name x --force` both parse).
            while i < arguments.count {
                switch arguments[i] {
                case "--force":
                    force = true
                    i += 1
                case "--name":
                    guard i + 1 < arguments.count else { return .usage }
                    name = arguments[i + 1]
                    i += 2
                default:
                    return .usage
                }
            }
            return .importKey(path: path, name: name, force: force)
        case "list-keys":
            return .listKeys
        case "remove-key":
            guard arguments.count == 3 else { return .usage }
            return .removeKey(name: arguments[2])
        default:
            return nil  // GUI launch (possibly with Apple's -NS… flags)
        }
    }

    /// True when the process was a CLI invocation and has been handled;
    /// the caller must then skip starting SwiftUI.
    static func run(arguments: [String]) -> Bool {
        guard let command = parse(arguments) else { return false }
        let store = KeychainKeyStore()
        do {
            switch command {
            case .usage:
                FileHandle.standardError.write(Data(usageText.utf8))
                exit(64)  // EX_USAGE
            case .importKey(let path, let name, let force):
                let data = try Data(contentsOf: URL(fileURLWithPath:
                                        (path as NSString).expandingTildeInPath))
                // Defaulting the name to the file's basename means two
                // different keys on disk (e.g. ~/.ssh/id_rsa and
                // ~/work/.ssh/id_rsa) can collide on the same library name.
                // The library is synced via iCloud Keychain, so a silent
                // overwrite would replace the key on every device. Requiring
                // --force is enforced by KeyImport.store.
                let keyName = name ?? PrivateKeyMaterial.defaultName(forPath: path)
                let key = try prepareInteractively(data, name: keyName)
                try KeyImport.store(key, into: store, force: force)
                print("Imported '\(keyName)'. It will appear in Sloop on all your devices (iCloud Keychain).")
            case .listKeys:
                let keys = try store.keys()
                if keys.isEmpty { print("No keys in the library.") }
                for key in keys {
                    print("\(key.name)\(key.passphrase != nil ? " (passphrase stored)" : "")")
                }
            case .removeKey(let name):
                try store.removeKey(named: name)
                print("Removed '\(name)' from the library. If any host predates the key " +
                      "library, it may still have its own legacy copy of this key stored " +
                      "per-host; edit that host and re-pick its key to clear it.")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        return true
    }

    /// Resolves a passphrase by asking the key, not by guessing at its
    /// envelope.
    ///
    /// The old `isEncryptedPEM` searched the PEM for the literal string
    /// "ENCRYPTED" and for "bcrypt" in the decoded body, and so missed an
    /// OpenSSH-format key using any other KDF — which imported silently with no
    /// passphrase and failed later at connect. Here the parse is simply
    /// attempted; libssh2 refusing it with none supplied is the prompt.
    static func prepareInteractively(_ data: Data, name: String) throws -> NamedKey {
        switch KeyImport.prepare(data, name: name, passphrase: nil) {
        case .success(let key):
            return key
        case .failure(.needsPassphrase):
            guard let raw = getpass("Key passphrase: ") else {
                throw KeyImportError.needsPassphrase
            }
            return try KeyImport.prepare(data, name: name,
                                         passphrase: String(cString: raw)).get()
        case .failure(let error):
            throw error
        }
    }

    private static let usageText = """
    usage: sloop import-key <path> [--name <name>] [--force]
           sloop list-keys
           sloop remove-key <name>

    """
}

#endif
