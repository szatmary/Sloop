// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class RemoteKeysTests: XCTestCase {

    private func populated() -> InMemorySFTPClient {
        let client = InMemorySFTPClient(home: "/home/matt")
        let ssh = "/home/matt/.ssh"
        for (name, body) in [
            ("id_ed25519",      "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"),
            ("id_ed25519.pub",  "ssh-ed25519 AAAA matt@laptop"),
            ("id_rsa",          "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"),
            ("id_rsa.pub",      "ssh-rsa AAAA matt@laptop"),
            ("known_hosts",     "example.com ssh-ed25519 AAAA"),
            ("config",          "Host web\n  User matt"),
            ("authorized_keys", "ssh-ed25519 AAAA someone"),
        ] {
            client.addFile("\(ssh)/\(name)", contents: Data(body.utf8))
        }
        return client
    }

    func testOffersOnlyPlausiblePrivateKeys() throws {
        let client = populated()
        let names = try RemoteKeys.candidates(in: client,
                                              sshDirectory: RemoteKeys.directory(in: "/home/matt"))
            .map(\.name)
        XCTAssertEqual(names, ["id_ed25519", "id_rsa"])
    }

    /// Directories in ~/.ssh (a `control` socket dir, someone's backup folder)
    /// are not keys and must not be offered as ones.
    func testSkipsDirectories() throws {
        let client = populated()
        client.addDirectory("/home/matt/.ssh/backups")
        let names = try RemoteKeys.candidates(in: client,
                                              sshDirectory: RemoteKeys.directory(in: "/home/matt"))
            .map(\.name)
        XCTAssertFalse(names.contains("backups"))
    }

    /// Listing must not read anything: the point of filtering by name is that
    /// choosing what to show never copies key material off the server.
    func testListingReadsNoFiles() throws {
        let client = populated()
        _ = try RemoteKeys.candidates(in: client,
                                      sshDirectory: RemoteKeys.directory(in: "/home/matt"))
        XCTAssertEqual(client.listCount, 1)
    }

    func testReadsAChosenKey() throws {
        let client = populated()
        let entry = try XCTUnwrap(
            RemoteKeys.candidates(in: client,
                                  sshDirectory: RemoteKeys.directory(in: "/home/matt"))
                .first { $0.name == "id_ed25519" })
        let data = try RemoteKeys.read(entry, from: client)
        XCTAssertEqual(PrivateKeyMaterial.recognize(data).envelope, .openssh)
    }

    /// The cap is the reason readData exists separately from the streaming
    /// read. Picking a disk image by mistake must fail, not fill memory.
    func testRefusesAFileLargerThanTheCap() {
        let client = InMemorySFTPClient(home: "/home/matt")
        client.addFile("/home/matt/.ssh/enormous",
                       contents: Data(repeating: 0x41, count: RemoteKeys.maximumBytes + 1))
        XCTAssertThrowsError(try client.readData("/home/matt/.ssh/enormous",
                                                 maximumBytes: RemoteKeys.maximumBytes)) {
            XCTAssertEqual($0 as? SFTPError,
                           .tooLarge("/home/matt/.ssh/enormous", limit: RemoteKeys.maximumBytes))
        }
    }

    func testAFileExactlyAtTheCapIsAllowed() throws {
        let client = InMemorySFTPClient(home: "/home/matt")
        client.addFile("/home/matt/.ssh/big",
                       contents: Data(repeating: 0x41, count: RemoteKeys.maximumBytes))
        XCTAssertEqual(try client.readData("/home/matt/.ssh/big",
                                           maximumBytes: RemoteKeys.maximumBytes).count,
                       RemoteKeys.maximumBytes)
    }

    /// A home directory with no ~/.ssh at all is the common case for a fresh
    /// account, and the caller needs to tell it apart from "no keys in there".
    func testMissingSSHDirectoryFailsAsSuch() {
        let client = InMemorySFTPClient(home: "/home/matt")
        XCTAssertThrowsError(try RemoteKeys.candidates(
            in: client, sshDirectory: RemoteKeys.directory(in: "/home/matt"))) {
            XCTAssertEqual($0 as? SFTPError, .noSuchFile("/home/matt/.ssh"))
        }
    }

    func testDirectoryIsBuiltFromTheHomePath() {
        XCTAssertEqual(RemoteKeys.directory(in: "/home/matt"), "/home/matt/.ssh")
        XCTAssertEqual(RemoteKeys.directory(in: "/home/matt/"), "/home/matt/.ssh")
    }
}

private extension Result where Success == PrivateKeyMaterial.Recognized,
                               Failure == PrivateKeyMaterial.Rejection {
    var envelope: PrivateKeyMaterial.Envelope? {
        if case .success(let r) = self { return r.envelope }
        return nil
    }
}
