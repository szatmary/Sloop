import XCTest
@testable import SloopKit

final class SloopKitTests: XCTestCase {

    func testEchoTransportEchoesPrintableInput() {
        let transport = EchoTransport()
        var out: [UInt8] = []
        transport.onData = { out.append(contentsOf: $0) }
        transport.start()
        out.removeAll()                       // drop the banner + first prompt

        transport.send(ArraySlice(Array("hi".utf8)))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hi")
    }

    func testEchoTransportReturnStartsNewPrompt() {
        let transport = EchoTransport()
        var out: [UInt8] = []
        transport.onData = { out.append(contentsOf: $0) }
        transport.start()
        out.removeAll()

        transport.send(ArraySlice([0x0d]))    // Return
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "\r\n$ ")
    }

    func testMoshBootstrapParsesBanner() {
        let banner = "Some preamble\nMOSH CONNECT 60001 x9FkQ2Zt==\nbye\n"
        let boot = MoshBootstrap(serverBanner: banner)
        XCTAssertEqual(boot, MoshBootstrap(udpPort: 60001, key: "x9FkQ2Zt=="))
    }

    func testMoshBootstrapRejectsGarbage() {
        XCTAssertNil(MoshBootstrap(serverBanner: "no mosh line here\n"))
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

    func testKnownHostsTrustOnFirstUse() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = KnownHostsStore(fileURL: tmp)
        let endpoint = KnownHostsStore.endpoint(host: "example.com", port: 22)
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA"), .unknown)

        store.remember(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA")
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "AAAA"), .match)
        XCTAssertEqual(store.status(endpoint: endpoint, keyType: "ssh-ed25519", fingerprint: "BBBB"), .mismatch)
    }

    func testKnownHostsPersistsAcrossInstances() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let endpoint = KnownHostsStore.endpoint(host: "h", port: 2222)
        KnownHostsStore(fileURL: tmp).remember(endpoint: endpoint, keyType: "ssh-rsa", fingerprint: "XX")
        XCTAssertEqual(KnownHostsStore(fileURL: tmp).status(endpoint: endpoint, keyType: "ssh-rsa", fingerprint: "XX"), .match)
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
