// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SloopKitTests: XCTestCase {

    func testConnectionStateLabelsAndFlags() {
        XCTAssertEqual(ConnectionState.connecting.label, "Connecting…")
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isConnected)

        let dropped = ConnectionState.disconnected(reason: "timeout")
        XCTAssertTrue(dropped.isDisconnected)
        XCTAssertEqual(dropped.label, "Disconnected — timeout")
        XCTAssertEqual(ConnectionState.disconnected(reason: nil).label, "Disconnected")
    }

    func testMoshBootstrapParsesBanner() {
        let banner = "Some preamble\nMOSH CONNECT 60001 x9FkQ2Zt==\nbye\n"
        let boot = MoshBootstrap(serverBanner: banner)
        XCTAssertEqual(boot, MoshBootstrap(udpPort: 60001, key: "x9FkQ2Zt=="))
    }

    func testMoshBootstrapRejectsGarbage() {
        XCTAssertNil(MoshBootstrap(serverBanner: "no mosh line here\n"))
    }

    /// Host files written before `onConnectCommand` existed must still decode.
    func testHostDecodesWithoutOnConnectCommand() throws {
        let json = """
        {"id":"8B9C0D1E-2F3A-4B5C-6D7E-8F9A0B1C2D3E","alias":"box",
         "hostname":"example.com","port":22,"username":"matt",
         "auth":{"password":{}},"useMosh":false}
        """
        let host = try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))
        XCTAssertNil(host.onConnectCommand)
        XCTAssertNil(host.trimmedOnConnectCommand)
    }

    /// Blank commands must read as "nothing to run", so no caller has to guess
    /// whether whitespace counts.
    func testTrimmedOnConnectCommand() {
        func host(_ command: String?) -> SSHHost {
            SSHHost(alias: "box", hostname: "example.com", username: "matt",
                    onConnectCommand: command)
        }
        XCTAssertNil(host(nil).trimmedOnConnectCommand)
        XCTAssertNil(host("").trimmedOnConnectCommand)
        XCTAssertNil(host("  \n ").trimmedOnConnectCommand)
        XCTAssertEqual(host("  tmux a\n").trimmedOnConnectCommand, "tmux a")
    }

    func testHostStoreRoundTrips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = HostStore(fileURL: tmp)
        store.upsert(SSHHost(alias: "box", hostname: "example.com", username: "matt"))

        let reloaded = HostStore(fileURL: tmp)
        XCTAssertEqual(reloaded.hosts.count, 1)
        XCTAssertEqual(reloaded.hosts.first?.alias, "box")
        XCTAssertEqual(reloaded.hosts.first?.connectionSummary, "matt@example.com")
    }

    func testMessageTransportEmitsThenCloses() {
        let transport = MessageTransport(message: "hello")
        var out: [UInt8] = []
        var closed = false
        transport.onData = { out.append(contentsOf: $0) }
        transport.onClose = { _ in closed = true }
        transport.start()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello")
        XCTAssertTrue(closed)
    }

    func testKnownHostsTrustOnFirstUse() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = KnownHostsStore(fileURL: tmp)
        let endpoint = KnownHostsStore.endpoint(host: "example.com", port: 22)
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA"), .unknown)

        try store.remember(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA")
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA"), .match)
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "BBBB"), .mismatch)
    }

    func testKnownHostsRecordedReturnsStoredKey() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = KnownHostsStore(fileURL: tmp)
        let endpoint = KnownHostsStore.endpoint(host: "example.com", port: 22)
        XCTAssertNil(store.recorded(endpoint: endpoint))

        try store.remember(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA")
        let recorded = store.recorded(endpoint: endpoint)
        XCTAssertEqual(recorded?.keyType, "ssh-ed25519")
        XCTAssertEqual(recorded?.fingerprint, "AAAA")

        // After a changed key is accepted, the recorded fingerprint updates.
        try store.remember(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "BBBB")
        XCTAssertEqual(store.recorded(endpoint: endpoint)?.fingerprint, "BBBB")
    }

    func testKnownHostsPersistsAcrossInstances() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let endpoint = KnownHostsStore.endpoint(host: "h", port: 2222)
        try KnownHostsStore(fileURL: tmp).remember(endpoint: endpoint, keyType: "ssh-rsa", fingerprint: "XX")
        XCTAssertEqual(KnownHostsStore(fileURL: tmp).status(endpoint: endpoint, keyType: "ssh-rsa", fingerprint: "XX"), .match)
    }

    /// A damaged record must fail that endpoint closed. Reporting `.unknown`
    /// would show the trust-on-first-use prompt, which is exactly what an
    /// attacker who can corrupt one line is after.
    func testKnownHostsUnreadableRecordFailsClosedForThatHostOnly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // One good record, one that names its endpoint but has lost its key.
        let json = """
        [{"endpoint":"good:22","keyType":"ssh-ed25519","fingerprint":"AAAA"},
         {"endpoint":"damaged:22","keyType":"ssh-ed25519"}]
        """
        try Data(json.utf8).write(to: tmp)

        let store = KnownHostsStore(fileURL: tmp)
        XCTAssertEqual(store.status(endpoint: "good:22", keyType: "ssh-ed25519", fingerprint: "AAAA"),
                       .match, "an intact record must still work")
        XCTAssertEqual(store.status(endpoint: "damaged:22", keyType: "ssh-ed25519", fingerprint: "AAAA"),
                       .mismatch, "an unreadable pin must refuse, not fall back to first-use trust")
        XCTAssertEqual(store.status(endpoint: "never-seen:22", keyType: "ssh-ed25519", fingerprint: "AAAA"),
                       .unknown, "other hosts are unaffected")
    }

    /// An unparseable file must not be silently emptied and then overwritten —
    /// that destroys every pin the user has, with no error at any point.
    func testKnownHostsPreservesAnUnparseableFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        let quarantine = tmp.deletingLastPathComponent()
            .appendingPathComponent(tmp.lastPathComponent + ".unreadable")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: quarantine)
        }

        let original = Data("{ this is not the file you are looking for".utf8)
        try original.write(to: tmp)

        let store = KnownHostsStore(fileURL: tmp)
        try store.remember(endpoint: "h:22", keyType: "ssh-ed25519", fingerprint: "AAAA")

        XCTAssertEqual(try Data(contentsOf: quarantine), original,
                       "the unreadable file must be moved aside, not destroyed")
        XCTAssertEqual(KnownHostsStore(fileURL: tmp)
                        .status(endpoint: "h:22", keyType: "ssh-ed25519", fingerprint: "AAAA"),
                       .match, "and the store must be usable again afterwards")
    }

    /// The store is shared by every connection and SSH runs on its own threads
    /// (a Mosh host alone runs two), so concurrent access must not corrupt the
    /// entry list.
    func testKnownHostsSurvivesConcurrentAccess() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = KnownHostsStore(fileURL: tmp)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let endpoint = "host-\(i % 20):22"
            try? store.remember(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "F\(i)")
            _ = store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "F\(i)")
            _ = store.recorded(endpoint: endpoint)
        }

        // Every endpoint written must be readable, and none may have been lost.
        for i in 0..<20 {
            XCTAssertNotNil(store.recorded(endpoint: "host-\(i):22"))
        }
    }

    func testInMemoryCredentialStoreRoundTrips() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        XCTAssertNil(store.credential(for: id))
        try store.setCredential(Credential(password: "secret"), for: id)
        XCTAssertEqual(store.credential(for: id)?.password, "secret")
        try store.removeCredential(for: id)
        XCTAssertNil(store.credential(for: id))
    }

    func testPrivateKeyCredentialRoundTrips() throws {
        // The keychain store serializes Credential as JSON — private keys must
        // survive the round trip.
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----"
        let store = InMemoryCredentialStore()
        let id = UUID()
        try store.setCredential(Credential(privateKeyPEM: pem, passphrase: "pw"), for: id)

        let data = try JSONEncoder().encode(store.credential(for: id))
        let decoded = try JSONDecoder().decode(Credential.self, from: data)
        XCTAssertEqual(decoded.privateKeyPEM, pem)
        XCTAssertEqual(decoded.passphrase, "pw")
        XCTAssertNil(decoded.password)
    }

    func testHostStoreUpsertReplacesSameID() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = HostStore(fileURL: tmp)
        var host = SSHHost(alias: "box", hostname: "example.com", username: "matt")
        store.upsert(host)
        host.alias = "renamed"
        store.upsert(host)

        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts.first?.alias, "renamed")
    }
}
