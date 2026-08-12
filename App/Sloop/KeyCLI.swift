import Foundation
import SloopKit

#if os(macOS)
/// Key-library subcommands embedded in the app binary, so imports run with
/// the app's signature and entitlements (a plain script cannot write the
/// shared, synchronizable keychain). Invoked via Scripts/sloop:
///
///     sloop import-key ~/.ssh/id_ed25519 [--name work]
///     sloop list-keys
///     sloop remove-key work
enum KeyCLI {
    enum Command: Equatable {
        case importKey(path: String, name: String?)
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
            if arguments.count == 3 { return .importKey(path: path, name: nil) }
            guard arguments.count == 5, arguments[3] == "--name" else { return .usage }
            return .importKey(path: path, name: arguments[4])
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
            case .importKey(let path, let name):
                let pem = try String(contentsOfFile: (path as NSString).expandingTildeInPath,
                                     encoding: .utf8)
                var passphrase: String?
                if isEncryptedPEM(pem), let raw = getpass("Key passphrase: ") {
                    passphrase = String(cString: raw)
                }
                let keyName = name ?? ((path as NSString).lastPathComponent)
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
                print("Removed '\(name)'.")
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
    usage: sloop import-key <path> [--name <name>]
           sloop list-keys
           sloop remove-key <name>

    """
}
#endif
