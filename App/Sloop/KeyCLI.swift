import Foundation
import SloopKit

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
                let pem = try String(contentsOfFile: (path as NSString).expandingTildeInPath,
                                     encoding: .utf8)
                var passphrase: String?
                if isEncryptedPEM(pem), let raw = getpass("Key passphrase: ") {
                    passphrase = String(cString: raw)
                }
                // Defaulting the name to the file's basename means two
                // different keys on disk (e.g. ~/.ssh/id_rsa and
                // ~/work/.ssh/id_rsa) can collide on the same library name.
                // The library is synced via iCloud Keychain, so a silent
                // overwrite here would silently replace the key on every
                // device. Require an explicit --force to overwrite.
                let keyName = name ?? ((path as NSString).lastPathComponent)
                if !force, store.key(named: keyName) != nil {
                    throw KeyExistsError(name: keyName)
                }
                try store.setKey(NamedKey(name: keyName, privateKeyPEM: pem, passphrase: passphrase))
                print("Imported '\(keyName)'. It will appear in Sloop on all your devices (iCloud Keychain).")
            case .listKeys:
                let keys = store.keys()
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

    /// Encrypted-PEM detection: PKCS#1/#8 headers say ENCRYPTED outright;
    /// openssh-key-v1 names its KDF ("bcrypt") in the base64 payload, which
    /// literally contains "none" instead when unencrypted.
    static func isEncryptedPEM(_ pem: String) -> Bool {
        if pem.contains("ENCRYPTED") { return true }
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: body),
              let text = String(data: decoded, encoding: .isoLatin1) else { return false }
        return text.contains("bcrypt")
    }

    private static let usageText = """
    usage: sloop import-key <path> [--name <name>] [--force]
           sloop list-keys
           sloop remove-key <name>

    """
}

/// Thrown by `import-key` when the target name already exists in the library
/// and `--force` wasn't given. A distinct type (rather than a bare `exit(1)`
/// at the call site) so the collision goes through the same error-formatting
/// path as every other CLI failure.
private struct KeyExistsError: LocalizedError {
    let name: String
    var errorDescription: String? {
        "a key named '\(name)' already exists in the library. Re-run with " +
        "--force to overwrite it on every synced device, or --name <other> " +
        "to import under a different name."
    }
}
#endif
