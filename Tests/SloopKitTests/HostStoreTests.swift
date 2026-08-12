import XCTest
@testable import SloopKit

final class HostStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-\(UUID().uuidString).json")
    }

    func testSkipsUndecodableHostsInsteadOfWipingTheList() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        [
          {"id":"6F1E2D3C-0000-0000-0000-000000000001","alias":"good",
           "hostname":"a.example.com","port":22,"username":"matt",
           "auth":{"password":{}},"useMosh":false},
          {"this is": "not a host"},
          {"id":"6F1E2D3C-0000-0000-0000-000000000002","alias":"future",
           "hostname":"b.example.com","port":22,"username":"matt",
           "auth":{"password":{}},"useMosh":false,
           "connectionMethod":"wireguard"}
        ]
        """
        try Data(json.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        XCTAssertEqual(store.hosts.map(\.alias), ["good"])
    }

    func testRoundTripSurvives() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        store.upsert(SSHHost(alias: "t", hostname: "h", username: "u",
                             connectionMethod: .cloudflareAccess))
        let reloaded = HostStore(fileURL: url)
        XCTAssertEqual(reloaded.hosts.first?.connectionMethod, .cloudflareAccess)
    }
}
